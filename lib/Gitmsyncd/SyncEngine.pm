package Gitmsyncd::SyncEngine;
use strict;
use warnings;
use File::Path qw(make_path rmtree);
use File::Spec;
use POSIX qw(strftime);
use Mojo::UserAgent;
use Exporter 'import';
our @EXPORT_OK = qw(run_sync_job branch_matches_filter check_repo_visibility);

# ── Branch filter matching (glob-style) ─────────────────────────────
sub branch_matches_filter {
    my ($branch, $filter) = @_;
    return 1 unless defined $filter && $filter =~ /\S/;  # NULL/empty = match all
    for my $pattern (split(/\s*,\s*/, $filter)) {
      next unless $pattern =~ /\S/;
      # Convert glob to regex: * matches anything except /
      (my $re = $pattern) =~ s/\*/.*/g;
      return 1 if $branch =~ /^$re$/;
    }
    return 0;
}

# ── Repo visibility check (governance: private→public prevention) ──
sub check_repo_visibility {
    my (%args) = @_;
    my $provider_type = $args{provider_type};
    my $base_url      = $args{base_url};
    my $token         = $args{token};
    my $full_path     = $args{full_path};

    my $ua = Mojo::UserAgent->new;
    $ua->connect_timeout(10);
    $ua->request_timeout(15);

    my ($url, %headers);
    if ($provider_type eq 'github') {
        $url = "https://api.github.com/repos/$full_path";
        %headers = ('Authorization' => "Bearer $token", 'Accept' => 'application/vnd.github+json', 'User-Agent' => 'gitmsyncd/1.0');
    } elsif ($provider_type eq 'gitlab') {
        my $base = $base_url || 'https://gitlab.com';
        $base =~ s{/+$}{};
        my $encoded_path = $full_path;
        $encoded_path =~ s{/}{%2F}g;
        $url = "$base/api/v4/projects/$encoded_path";
        %headers = ('PRIVATE-TOKEN' => $token);
    } elsif ($provider_type eq 'gitea') {
        my $base = $base_url || 'https://gitea.com';
        $base =~ s{/+$}{};
        $url = "$base/api/v1/repos/$full_path";
        %headers = ('Authorization' => "token $token");
    }

    my $tx = $ua->get($url => \%headers);
    my $res = $tx->result;

    if ($res && $res->is_success) {
        my $body = eval { $res->json } || {};
        if ($provider_type eq 'gitlab') {
            return $body->{visibility} || 'unknown';  # 'private', 'internal', 'public'
        } else {
            return $body->{private} ? 'private' : 'public';
        }
    }
    return 'unknown';  # can't determine, allow sync (fail open for unknown)
}

# ── Sync engine (shared by queue worker and direct run) ─────────
sub run_sync_job {
    my (%args) = @_;
    my $dbh        = $args{dbh};
    my $job_id     = $args{job_id};
    my $profile_id = $args{profile_id};
    my $workdir    = $args{workdir} || $ENV{GITMSYNCD_WORKDIR} || '/tmp/gitmsyncd-workdir';

    $dbh->do(q{UPDATE sync_jobs SET status='running', message='picked up by worker' WHERE id=?}, undef, $job_id);

    my $log_event = sub {
      my ($level, $msg) = @_;
      eval { $dbh->do(q{INSERT INTO sync_job_events (job_id, level, message) VALUES (?, ?, ?)}, undef, $job_id, $level, $msg); };
    };

    # Acquire lock — atomic UPDATE with stale lock breaker (30 min timeout)
    my $lock_acquired = $dbh->selectrow_hashref(
      q{UPDATE sync_profiles SET sync_locked = TRUE, sync_locked_at = NOW(), sync_locked_by = 'worker-' || pg_backend_pid()
        WHERE id = ? AND (sync_locked = FALSE OR sync_locked_at < NOW() - INTERVAL '30 minutes')
        RETURNING id}, undef, $profile_id
    );
    unless ($lock_acquired) {
      $log_event->('warn', "profile $profile_id is locked by another sync — skipping");
      $dbh->do(q{UPDATE sync_jobs SET status='stopped', finished_at=NOW(), message='skipped: profile locked by another sync' WHERE id=?}, undef, $job_id);
      return;
    }

    # Release lock helper — runs even on error
    my $release_lock = sub {
      eval { $dbh->do(q{UPDATE sync_profiles SET sync_locked = FALSE, sync_locked_at = NULL, sync_locked_by = NULL WHERE id = ?}, undef, $profile_id); };
    };

    # Wrap entire sync in eval so lock is always released
    eval {
      # Load profile with providers (including SSH settings)
      my $profile = $dbh->selectrow_hashref(
        q{SELECT sp.*,
                 src.provider_type AS src_type, src.base_url AS src_base_url, src.api_token AS src_token,
                 src.clone_protocol AS src_clone_proto, src.ssh_key_path AS src_ssh_key,
                 tgt.provider_type AS tgt_type, tgt.base_url AS tgt_base_url, tgt.api_token AS tgt_token,
                 tgt.push_protocol AS tgt_push_proto, tgt.ssh_key_path AS tgt_ssh_key
          FROM sync_profiles sp
          JOIN providers src ON sp.source_provider_id = src.id
          JOIN providers tgt ON sp.target_provider_id = tgt.id
          WHERE sp.id = ?}, undef, $profile_id
      );

      unless ($profile) {
        $log_event->('error', 'profile not found or providers missing');
        $dbh->do(q{UPDATE sync_jobs SET status='failed', finished_at=NOW(), message='profile not found' WHERE id=?}, undef, $job_id);
        return;
      }

      my @mappings = @{ $dbh->selectall_arrayref(
        q{SELECT * FROM repo_mappings WHERE profile_id = ? AND enabled = TRUE}, { Slice => {} }, $profile_id
      ) || [] };

      unless (@mappings) {
        $log_event->('warn', 'no active repo mappings found for this profile');
        $dbh->do(q{UPDATE sync_jobs SET status='success', finished_at=NOW(), message='no mappings to sync' WHERE id=?}, undef, $job_id);
        return;
      }

      $log_event->('info', "found " . scalar(@mappings) . " repo mapping(s) to sync");

      # Build clone/push URL — supports both HTTPS (token) and SSH (key)
      my $build_url = sub {
        my ($type, $base_url, $token, $full_path, $protocol) = @_;
        $protocol ||= 'https';

        if ($protocol eq 'ssh') {
          # SSH URLs
          if ($type eq 'github') {
            return "git\@github.com:$full_path.git";
          } elsif ($type eq 'gitlab') {
            my $base = $base_url || 'https://gitlab.com';
            my ($host) = $base =~ m{https?://([^/:]+)};
            $host ||= 'gitlab.com';
            return "git\@$host:$full_path.git";
          } elsif ($type eq 'gitea') {
            my $base = $base_url || 'https://gitea.com';
            my ($host) = $base =~ m{https?://([^/:]+)};
            my ($port) = $base =~ m{:(\d+)};
            $host ||= 'gitea.com';
            if ($port && $port ne '22') {
              return "ssh://git\@$host:$port/$full_path.git";
            }
            return "git\@$host:$full_path.git";
          }
        }

        # HTTPS URLs
        if ($type eq 'github') {
          return "https://$token\@github.com/$full_path.git";
        } elsif ($type eq 'gitlab') {
          my $base = $base_url || 'https://gitlab.com';
          $base =~ s{/+$}{};
          if ($base =~ m{^(https?)://(.+)}) { return "$1://oauth2:$token\@$2/$full_path.git"; }
          return "https://oauth2:$token\@$base/$full_path.git";
        } elsif ($type eq 'gitea') {
          my $base = $base_url || 'https://gitea.com';
          $base =~ s{/+$}{};
          if ($base =~ m{^(https?)://(.+)}) { return "$1://$token\@$2/$full_path.git"; }
          return "https://$token\@$base/$full_path.git";
        }
        return undef;
      };

      make_path($workdir) unless -d $workdir;
      my ($synced, $failed) = (0, 0);

      # Set up SSH command if source uses SSH
      my $src_proto = $profile->{src_clone_proto} || 'https';
      my $tgt_proto = $profile->{tgt_push_proto} || 'https';
      my $src_ssh_cmd = '';
      my $tgt_ssh_cmd = '';

      if ($src_proto eq 'ssh' && $profile->{src_ssh_key}) {
        $src_ssh_cmd = "GIT_SSH_COMMAND='ssh -i $profile->{src_ssh_key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no'";
      }
      if ($tgt_proto eq 'ssh' && $profile->{tgt_ssh_key}) {
        $tgt_ssh_cmd = "GIT_SSH_COMMAND='ssh -i $profile->{tgt_ssh_key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no'";
      }

      # Retry helper (exponential backoff)
      my $retry = sub {
        my ($attempts, $cmd) = @_;
        for my $n (1..$attempts) {
          my $out = `$cmd`;
          return (0, $out) if $? == 0;
          if ($n < $attempts) {
            my $delay = 2 * $n;
            $log_event->('warn', "attempt $n failed, retrying in ${delay}s...");
            sleep $delay;
          } else {
            return ($?, $out);
          }
        }
      };

      # Protected branches + conflict policy
      my @protected = split(/\s+/, $profile->{protected_branches} || 'main master develop');
      my %is_protected = map { $_ => 1 } @protected;
      my $conflict_policy = $profile->{conflict_policy} || 'ff-only';

      for my $m (@mappings) {
        # ── Governance: check private->public ──────────────────────
        my $src_vis = check_repo_visibility(
            provider_type => $profile->{src_type},
            base_url      => $profile->{src_base_url},
            token         => $profile->{src_token},
            full_path     => $m->{source_full_path},
        );
        my $tgt_vis = check_repo_visibility(
            provider_type => $profile->{tgt_type},
            base_url      => $profile->{tgt_base_url},
            token         => $profile->{tgt_token},
            full_path     => $m->{target_full_path},
        );

        # ── Governance: every sync decision recorded in ledger ─────

        # Check for admin block (any sync, any direction)
        my $admin_block = $dbh->selectrow_hashref(
            q{SELECT id, authorized_by, acknowledgment FROM sync_authorizations
              WHERE mapping_id = ? AND risk_level = 'admin_block' AND authorization_status = 'blocked'
              AND (revoked_at IS NULL)
              LIMIT 1}, undef, $m->{id});
        if ($admin_block) {
            $log_event->('error', "BLOCKED: sync '$m->{source_full_path}' -> '$m->{target_full_path}' administratively blocked by $admin_block->{authorized_by}");
            # Record in governance alerts
            eval { $dbh->do(
                q{INSERT INTO governance_alerts (alert_type, severity, mapping_id, profile_id, source_repo, target_repo, message)
                  VALUES ('admin_block', 'critical', ?, ?, ?, ?, ?)},
                undef, $m->{id}, $profile_id, $m->{source_full_path}, $m->{target_full_path},
                "Sync blocked by admin '$admin_block->{authorized_by}': $admin_block->{acknowledgment}"
            ); };
            $failed++; next;
        }

        # Check private→public
        if ($src_vis eq 'private' && $tgt_vis eq 'public') {
            my $auth = $dbh->selectrow_hashref(
                q{SELECT id, authorized_by FROM sync_authorizations
                  WHERE mapping_id = ? AND authorization_status = 'authorized'
                  AND (revoked_at IS NULL)
                  LIMIT 1}, undef, $m->{id});

            unless ($auth) {
                $log_event->('error', "BLOCKED: private repo '$m->{source_full_path}' -> public target '$m->{target_full_path}' (no authorization)");
                # Record blocked attempt in governance alerts
                eval { $dbh->do(
                    q{INSERT INTO governance_alerts (alert_type, severity, mapping_id, profile_id, source_repo, target_repo, message)
                      VALUES ('private_to_public_blocked', 'critical', ?, ?, ?, ?, ?)},
                    undef, $m->{id}, $profile_id, $m->{source_full_path}, $m->{target_full_path},
                    "Sync blocked: private repo '$m->{source_full_path}' cannot be synced to public target '$m->{target_full_path}' without admin authorization"
                ); };
                # Governance alert surfaces on dashboard. The authorization ledger
                # is only written by explicit admin decisions (authorize/block/revoke),
                # not by per-execution system events.
                $failed++; next;
            }
            $log_event->('info', "authorized private->public sync: $m->{source_full_path} -> $m->{target_full_path} (auth #$auth->{id}, by $auth->{authorized_by})");
        }
        # Normal syncs (not private→public, not admin-blocked) proceed without ledger entry.
        # The ledger records explicit decisions only: authorizations, blocks, revocations.

        my $src_url = $build_url->($profile->{src_type}, $profile->{src_base_url}, $profile->{src_token}, $m->{source_full_path}, $src_proto);
        my $tgt_url = $build_url->($profile->{tgt_type}, $profile->{tgt_base_url}, $profile->{tgt_token}, $m->{target_full_path}, $tgt_proto);

        unless ($src_url && $tgt_url) {
          $log_event->('error', "cannot build URLs for $m->{source_full_path}");
          $failed++; next;
        }

        (my $dir_name = $m->{source_full_path}) =~ s{/}{--}g;
        my $repo_dir = File::Spec->catdir($workdir, "$dir_name.git");

        $log_event->('info', "syncing $m->{source_full_path} -> $m->{target_full_path} [$src_proto/$tgt_proto] policy=$conflict_policy");

        # Clone with retry
        rmtree($repo_dir) if -d $repo_dir;
        my $clone_cmd = $src_ssh_cmd ? "$src_ssh_cmd git clone --mirror '$src_url' '$repo_dir' 2>&1" : "git clone --mirror '$src_url' '$repo_dir' 2>&1";
        my ($clone_rc, $clone_out) = $retry->(3, $clone_cmd);
        if ($clone_rc != 0) {
          $log_event->('error', "clone failed after 3 attempts for $m->{source_full_path}: $clone_out");
          $failed++; next;
        }

        # ── Debug tap helper (shared by source and target taps) ──
        my $debug_expired = 0;
        if (($m->{debug_source_tap} || $m->{debug_target_tap})
            && $m->{debug_expires_at}
            && $m->{debug_expires_at} lt strftime('%Y-%m-%d %H:%M:%S', localtime)) {
          eval { $dbh->do(q{UPDATE repo_mappings SET debug_source_tap = FALSE, debug_target_tap = FALSE, debug_expires_at = NULL WHERE id = ?}, undef, $m->{id}); };
          $log_event->('info', "debug taps expired for $m->{source_full_path}");
          $debug_expired = 1;
        }

        my $run_debug_tap = sub {
          my ($tap_name, $dir) = @_;
          my $cap = $m->{debug_file_cap} || 10;
          my $total = `git -C '$dir' ls-tree -r --name-only HEAD 2>/dev/null | wc -l` || 0;
          chomp $total;
          my @files = split(/\n/, `git -C '$dir' ls-tree -r --name-only HEAD 2>/dev/null | head -$cap`);
          my $branch_count = `git -C '$dir' for-each-ref --format='%(refname:strip=2)' refs/heads 2>/dev/null | wc -l` || 0;
          chomp $branch_count;
          my $size_kb = `du -sk '$dir' 2>/dev/null | cut -f1` || '?';
          chomp $size_kb;
          $log_event->('info', "[$tap_name] $m->{source_full_path}: $branch_count branches, $total files, ${size_kb}KB on disk");
          for my $f (@files) {
            chomp $f; next unless $f;
            my $fsize = `git -C '$dir' cat-file -s HEAD:"$f" 2>/dev/null` || '?';
            chomp $fsize;
            $log_event->('info', "[$tap_name]   $f ($fsize bytes)");
          }
          $log_event->('info', "[$tap_name]   ... and " . ($total - scalar(@files)) . " more files") if $total > scalar(@files);
        };

        # ── SOURCE TAP: fires after clone — "what did we get?" ──
        if ($m->{debug_source_tap} && !$debug_expired) {
          $run_debug_tap->('SOURCE', $repo_dir);
        }

        if ($conflict_policy eq 'reject') {
          # Fetch target, check for divergence, skip entirely if any branch diverged
          my $fetch_tgt = $tgt_ssh_cmd
            ? "cd '$repo_dir' && $tgt_ssh_cmd git fetch '$tgt_url' '+refs/heads/*:refs/remotes/destination/*' 2>&1"
            : "cd '$repo_dir' && git fetch '$tgt_url' '+refs/heads/*:refs/remotes/destination/*' 2>&1";
          `$fetch_tgt`;
          my $has_conflict = 0;
          my $has_filter = defined $m->{branch_filter} && $m->{branch_filter} =~ /\S/;
          my @reject_refspecs = ('refs/tags/*:refs/tags/*');
          for my $branch (split(/\n/, `git -C '$repo_dir' for-each-ref --format='%(refname:strip=2)' refs/heads`)) {
            chomp $branch; next unless $branch;
            next unless branch_matches_filter($branch, $m->{branch_filter});
            push @reject_refspecs, "refs/heads/$branch:refs/heads/$branch";
            my $dst = `git -C '$repo_dir' rev-parse -q --verify 'refs/remotes/destination/$branch' 2>/dev/null`;
            chomp $dst; next unless $dst;
            if (system("git -C '$repo_dir' merge-base --is-ancestor 'refs/remotes/destination/$branch' 'refs/heads/$branch' 2>/dev/null") != 0) {
              $log_event->('warn', "branch '$branch' diverged — conflict (reject policy)");
              $has_conflict = 1;
            }
          }
          if ($has_conflict) {
            $log_event->('warn', "skipping $m->{source_full_path} — divergence detected (reject)");
            $failed++; rmtree($repo_dir) if -d $repo_dir; next;
          }
          # No conflicts — push (use refspecs when filtered, mirror when not)
          my $push_cmd;
          if ($has_filter) {
            my $refspec_str = join(' ', map { "'$_'" } @reject_refspecs);
            $push_cmd = $tgt_ssh_cmd
              ? "cd '$repo_dir' && $tgt_ssh_cmd git push '$tgt_url' $refspec_str 2>&1"
              : "cd '$repo_dir' && git push '$tgt_url' $refspec_str 2>&1";
          } else {
            $push_cmd = $tgt_ssh_cmd ? "cd '$repo_dir' && $tgt_ssh_cmd git push --mirror '$tgt_url' 2>&1" : "cd '$repo_dir' && git push --mirror '$tgt_url' 2>&1";
          }
          my ($push_rc, $push_out) = $retry->(3, $push_cmd);
          if ($push_rc != 0) { $log_event->('error', "push failed: $push_out"); $failed++; }
          else { $log_event->('info', "synced $m->{source_full_path} -> $m->{target_full_path} (reject policy, clean)"); $synced++; }

        } elsif ($conflict_policy eq 'force-push') {
          # Force push — source is authoritative
          my $push_cmd;
          if (defined $m->{branch_filter} && $m->{branch_filter} =~ /\S/) {
            # Branch filter active: enumerate, filter, force-push matching branches
            my @fp_refspecs = ('refs/tags/*:refs/tags/*');
            for my $branch (split(/\n/, `git -C '$repo_dir' for-each-ref --format='%(refname:strip=2)' refs/heads`)) {
              chomp $branch; next unless $branch;
              next unless branch_matches_filter($branch, $m->{branch_filter});
              push @fp_refspecs, "+refs/heads/$branch:refs/heads/$branch";
            }
            my $refspec_str = join(' ', map { "'$_'" } @fp_refspecs);
            $push_cmd = $tgt_ssh_cmd
              ? "cd '$repo_dir' && $tgt_ssh_cmd git push --force '$tgt_url' $refspec_str 2>&1"
              : "cd '$repo_dir' && git push --force '$tgt_url' $refspec_str 2>&1";
          } else {
            # No filter — mirror force push (original behavior)
            $push_cmd = $tgt_ssh_cmd ? "cd '$repo_dir' && $tgt_ssh_cmd git push --mirror --force '$tgt_url' 2>&1" : "cd '$repo_dir' && git push --mirror --force '$tgt_url' 2>&1";
          }
          my ($push_rc, $push_out) = $retry->(3, $push_cmd);
          if ($push_rc != 0) { $log_event->('error', "push failed: $push_out"); $failed++; }
          else { $log_event->('info', "synced $m->{source_full_path} -> $m->{target_full_path} (force-push)"); $synced++; }

        } else {
          # ff-only (default): per-branch conflict check on protected branches
          my $fetch_tgt = $tgt_ssh_cmd
            ? "cd '$repo_dir' && $tgt_ssh_cmd git fetch '$tgt_url' '+refs/heads/*:refs/remotes/destination/*' 2>&1"
            : "cd '$repo_dir' && git fetch '$tgt_url' '+refs/heads/*:refs/remotes/destination/*' 2>&1";
          `$fetch_tgt`;
          my @refspecs = ('refs/tags/*:refs/tags/*');
          my $skipped = 0;
          for my $branch (split(/\n/, `git -C '$repo_dir' for-each-ref --format='%(refname:strip=2)' refs/heads`)) {
            chomp $branch; next unless $branch;
            next unless branch_matches_filter($branch, $m->{branch_filter});
            if ($is_protected{$branch}) {
              my $dst = `git -C '$repo_dir' rev-parse -q --verify 'refs/remotes/destination/$branch' 2>/dev/null`;
              chomp $dst;
              if ($dst && system("git -C '$repo_dir' merge-base --is-ancestor 'refs/remotes/destination/$branch' 'refs/heads/$branch' 2>/dev/null") != 0) {
                $log_event->('warn', "protected branch '$branch' diverged — skipping (ff-only)");
                $skipped++; next;
              }
            }
            push @refspecs, "refs/heads/$branch:refs/heads/$branch";
          }
          $log_event->('warn', "$skipped protected branch(es) skipped (non-fast-forward)") if $skipped;
          my $refspec_str = join(' ', map { "'$_'" } @refspecs);
          my $push_cmd = $tgt_ssh_cmd
            ? "cd '$repo_dir' && $tgt_ssh_cmd git push --prune '$tgt_url' $refspec_str 2>&1"
            : "cd '$repo_dir' && git push --prune '$tgt_url' $refspec_str 2>&1";
          my ($push_rc, $push_out) = $retry->(3, $push_cmd);
          if ($push_rc != 0) { $log_event->('error', "push failed: $push_out"); $failed++; }
          else { $log_event->('info', "synced $m->{source_full_path} -> $m->{target_full_path} (ff-only, $skipped skipped)"); $synced++; }
        }

        # ── TARGET TAP: fires after push — "what landed on the target?" ──
        if ($m->{debug_target_tap} && !$debug_expired) {
          # Fetch back from target into a temporary remote to see what's there
          my $fetch_verify = $tgt_ssh_cmd
            ? "cd '$repo_dir' && $tgt_ssh_cmd git fetch '$tgt_url' '+refs/heads/*:refs/remotes/target-verify/*' 2>&1"
            : "cd '$repo_dir' && git fetch '$tgt_url' '+refs/heads/*:refs/remotes/target-verify/*' 2>&1";
          my $fetch_out = `$fetch_verify`;
          my $target_branches = `git -C '$repo_dir' for-each-ref --format='%(refname:strip=3)' refs/remotes/target-verify 2>/dev/null` || '';
          my @tbranches = grep { $_ } split(/\n/, $target_branches);
          $log_event->('info', "[TARGET] $m->{target_full_path}: " . scalar(@tbranches) . " branches on target after push");
          for my $tb (@tbranches) {
            chomp $tb;
            my $commit = `git -C '$repo_dir' rev-parse --short 'refs/remotes/target-verify/$tb' 2>/dev/null` || '?';
            chomp $commit;
            $log_event->('info', "[TARGET]   branch: $tb -> $commit");
          }
          # Also show files from target's HEAD (first N)
          if (@tbranches) {
            my $default_branch = $tbranches[0];  # first branch as proxy for HEAD
            my $cap = $m->{debug_file_cap} || 10;
            my @tfiles = split(/\n/, `git -C '$repo_dir' ls-tree -r --name-only 'refs/remotes/target-verify/$default_branch' 2>/dev/null | head -$cap`);
            my $ttotal = `git -C '$repo_dir' ls-tree -r --name-only 'refs/remotes/target-verify/$default_branch' 2>/dev/null | wc -l` || 0;
            chomp $ttotal;
            $log_event->('info', "[TARGET]   $ttotal files on target (showing first $cap):");
            for my $f (@tfiles) {
              chomp $f; next unless $f;
              $log_event->('info', "[TARGET]     $f");
            }
          }
        }

        rmtree($repo_dir) if -d $repo_dir;
      }

      my $status = $failed > 0 ? 'failed' : 'success';
      my $msg = "synced=$synced failed=$failed total=" . scalar(@mappings);
      $log_event->('info', "job finished: $msg");
      $dbh->do(q{UPDATE sync_jobs SET status=?, finished_at=NOW(), message=? WHERE id=?}, undef, $status, $msg, $job_id);

      # Update last_synced_at on the profile
      $dbh->do(q{UPDATE sync_profiles SET last_synced_at = NOW() WHERE id = ?}, undef, $profile_id);
    };
    # Capture any error from the eval block
    my $sync_err = $@;
    if ($sync_err) {
      $log_event->('error', "sync crashed: $sync_err");
      eval { $dbh->do(q{UPDATE sync_jobs SET status='failed', finished_at=NOW(), message=? WHERE id=?}, undef, "internal error: $sync_err", $job_id); };
    }

    # ALWAYS release the lock, even if sync threw an error
    $release_lock->();
}

1;
