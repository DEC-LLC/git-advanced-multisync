#!/usr/bin/env perl
use strict;
use warnings;
use DBI;
use Getopt::Long;
use POSIX qw(strftime :sys_wait_h);
use Sys::Hostname;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Gitmsyncd::SyncEngine qw(run_sync_job);
use Gitmsyncd::ResourceGovernor qw(check_resources);

# ── Configuration ──────────────────────────────────────────
my $set_name;
GetOptions('set=s' => \$set_name);

my $dsn       = $ENV{GITMSYNCD_DSN}      || 'dbi:Pg:dbname=gitmsyncd;host=127.0.0.1;port=5432';
my $db_user   = $ENV{GITMSYNCD_DB_USER}  || 'gitmsyncd';
my $db_pass   = $ENV{GITMSYNCD_DB_PASS}  || 'gitmsyncd';
my $workdir   = $ENV{GITMSYNCD_WORKDIR}  || '/tmp/gitmsyncd-workdir';
my $max_forks = $ENV{GITMSYNCD_MAX_FORKS}    || 4;
my $max_load  = $ENV{GITMSYNCD_MAX_LOAD}     || 3.2;
my $min_mem   = $ENV{GITMSYNCD_MIN_MEM_MB}   || 256;
my $min_disk  = $ENV{GITMSYNCD_MIN_DISK_MB}  || 1024;
my $poll_interval = 5;  # seconds

# ── Database helper ────────────────────────────────────────
sub db_connect {
    return DBI->connect($dsn, $db_user, $db_pass, {
        RaiseError => 1, AutoCommit => 1, pg_enable_utf8 => 1
    });
}

# ── Signal handling ────────────────────────────────────────
my $stopping = 0;
$SIG{TERM} = $SIG{INT} = sub { $stopping = 1; };

# ── Child tracking ─────────────────────────────────────────
my %children;  # pid => { job_id => N, started => time }

# ── Register worker ────────────────────────────────────────
my $dbh = db_connect();
my $hostname = hostname();
$dbh->do(q{
    INSERT INTO workers (worker_set, hostname, pid, status, started_at, last_heartbeat_at)
    VALUES (?, ?, ?, 'running', NOW(), NOW())
}, undef, $set_name || 'default', $hostname, $$);
my $worker_id = $dbh->last_insert_id(undef, undef, 'workers', 'id');

print "[worker $$] registered as worker_id=$worker_id set=" . ($set_name || 'default') . " on $hostname\n";

# ── Main loop ──────────────────────────────────────────────
while (!$stopping) {
    eval {
        # Heartbeat + check paused flag from DB (set by web UI)
        $dbh->do(q{UPDATE workers SET last_heartbeat_at = NOW(), active_forks = ? WHERE id = ?},
            undef, scalar(keys %children), $worker_id);
        my $worker_row = $dbh->selectrow_hashref(
            q{SELECT paused, status FROM workers WHERE id = ?}, undef, $worker_id);

        # If web UI set status to 'stopped', honor it
        if ($worker_row && $worker_row->{status} eq 'stopped') {
            print "[worker $$] stop requested via UI\n";
            $stopping = 1;
        }

        # Reap finished children
        while ((my $kid = waitpid(-1, WNOHANG)) > 0) {
            my $exit_code = $? >> 8;
            my $info = delete $children{$kid};
            if ($info) {
                print "[worker $$] child $kid finished (job $info->{job_id}, exit=$exit_code)\n";
            }
        }

        # Skip if paused (still heartbeat and reap, but don't pick up new work)
        if ($worker_row && $worker_row->{paused}) {
            $dbh->do(q{UPDATE workers SET status = 'paused' WHERE id = ? AND status != 'paused'}, undef, $worker_id);
            # still sleep at bottom
        }

        # Skip if at capacity, stopping, or paused
        my $active = scalar(keys %children);
        if ($active >= $max_forks || $stopping || ($worker_row && $worker_row->{paused})) {
            # still need to sleep at bottom
        } else {
            # Ensure status shows running if we were previously paused
            $dbh->do(q{UPDATE workers SET status = 'running' WHERE id = ? AND status = 'paused'}, undef, $worker_id);
            # Check resource governor
            my ($res_ok, $res_msg) = check_resources(
                max_load    => $max_load,
                min_mem_mb  => $min_mem,
                min_disk_mb => $min_disk,
                workdir     => $workdir,
            );
            if (!$res_ok) {
                print "[worker $$] throttled: $res_msg\n";
            } else {
                # Find work: queued jobs for our set (or all if no set filter)
                my $job;
                if ($set_name) {
                    $job = $dbh->selectrow_hashref(q{
                        SELECT sj.id, sj.profile_id FROM sync_jobs sj
                        JOIN sync_profiles sp ON sj.profile_id = sp.id
                        LEFT JOIN worker_sets ws ON sp.worker_set_id = ws.id
                        WHERE sj.status = 'queued'
                          AND (ws.name = ? OR sp.worker_set_id IS NULL)
                        ORDER BY sj.id LIMIT 1
                        FOR UPDATE OF sj SKIP LOCKED
                    }, undef, $set_name);
                } else {
                    $job = $dbh->selectrow_hashref(q{
                        SELECT id, profile_id FROM sync_jobs
                        WHERE status = 'queued'
                        ORDER BY id LIMIT 1
                        FOR UPDATE SKIP LOCKED
                    });
                }

                # If no queued job, check for scheduled profiles due now
                if (!$job) {
                    my $due;
                    if ($set_name) {
                        $due = $dbh->selectrow_hashref(q{
                            SELECT sp.id FROM sync_profiles sp
                            LEFT JOIN worker_sets ws ON sp.worker_set_id = ws.id
                            WHERE sp.enabled = TRUE
                              AND sp.sync_interval_minutes IS NOT NULL
                              AND sp.sync_interval_minutes > 0
                              AND sp.next_sync_at IS NOT NULL
                              AND sp.next_sync_at <= NOW()
                              AND (sp.sync_locked = FALSE OR sp.sync_locked_at < NOW() - INTERVAL '30 minutes')
                              AND (ws.name = ? OR sp.worker_set_id IS NULL)
                            ORDER BY sp.next_sync_at ASC LIMIT 1
                        }, undef, $set_name);
                    } else {
                        $due = $dbh->selectrow_hashref(q{
                            SELECT id FROM sync_profiles
                            WHERE enabled = TRUE
                              AND sync_interval_minutes IS NOT NULL
                              AND sync_interval_minutes > 0
                              AND next_sync_at IS NOT NULL
                              AND next_sync_at <= NOW()
                              AND (sync_locked = FALSE OR sync_locked_at < NOW() - INTERVAL '30 minutes')
                            ORDER BY next_sync_at ASC LIMIT 1
                        });
                    }
                    if ($due) {
                        # Create job row + bump next_sync_at
                        $dbh->do(q{INSERT INTO sync_jobs (profile_id, status, started_at, message)
                                   VALUES (?, 'queued', NOW(), 'scheduled by worker')}, undef, $due->{id});
                        my $new_job_id = $dbh->last_insert_id(undef, undef, 'sync_jobs', 'id');
                        $dbh->do(q{UPDATE sync_profiles SET next_sync_at = NOW() + (sync_interval_minutes || ' minutes')::interval
                                   WHERE id = ?}, undef, $due->{id});
                        $job = { id => $new_job_id, profile_id => $due->{id} };
                    }
                }

                # Fork child to process job
                if ($job) {
                    my $job_id     = $job->{id};
                    my $profile_id = $job->{profile_id};

                    # Mark as running before fork
                    $dbh->do(q{UPDATE sync_jobs SET status='running', message='picked up by worker' WHERE id=? AND status='queued'}, undef, $job_id);

                    # CRITICAL: disconnect before fork — child must create own connection
                    $dbh->disconnect;

                    my $pid = fork();
                    if (!defined $pid) {
                        warn "[worker $$] fork failed: $!\n";
                        $dbh = db_connect();  # reconnect parent
                    } elsif ($pid == 0) {
                        # ── CHILD PROCESS ──
                        my $child_dbh = db_connect();
                        eval {
                            run_sync_job(
                                dbh        => $child_dbh,
                                job_id     => $job_id,
                                profile_id => $profile_id,
                                workdir    => $workdir,
                            );
                        };
                        if ($@) {
                            warn "[child $$] sync crashed: $@\n";
                            eval { $child_dbh->do(q{UPDATE sync_jobs SET status='failed', finished_at=NOW(), message=? WHERE id=?},
                                undef, "child crash: $@", $job_id); };
                        }
                        $child_dbh->disconnect;
                        exit 0;
                    } else {
                        # ── PARENT ──
                        $children{$pid} = { job_id => $job_id, started => time() };
                        $dbh = db_connect();  # reconnect parent
                        print "[worker $$] forked child $pid for job $job_id (profile $profile_id)\n";
                    }
                }
            }
        }
    };
    if ($@) {
        warn "[worker $$] main loop error: $@\n";
        eval { $dbh = db_connect(); };  # try to reconnect
    }

    sleep $poll_interval unless $stopping;
}

# ── Graceful shutdown ──────────────────────────────────────
print "[worker $$] stopping, waiting for " . scalar(keys %children) . " children...\n";
# Wait for all children with timeout
my $wait_start = time();
while (keys %children && (time() - $wait_start) < 300) {  # 5 min max wait
    while ((my $kid = waitpid(-1, WNOHANG)) > 0) {
        delete $children{$kid};
    }
    sleep 1 if keys %children;
}
# Kill stragglers
for my $pid (keys %children) {
    kill 'TERM', $pid;
    waitpid($pid, 0);
}

# Deregister
eval {
    $dbh->do(q{UPDATE workers SET status = 'stopped', last_heartbeat_at = NOW() WHERE id = ?}, undef, $worker_id);
};
$dbh->disconnect if $dbh;

print "[worker $$] shutdown complete\n";
