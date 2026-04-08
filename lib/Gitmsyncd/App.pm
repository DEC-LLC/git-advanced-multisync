package Gitmsyncd::App;
use strict;
use warnings;
use Mojolicious::Lite -signatures;
use DBI;
use FindBin;
use File::Path qw(make_path rmtree);
use File::Spec;
use POSIX qw(strftime);

sub start {
  my ($self) = @_;

  # Set template and static paths relative to project root
  my $root = "$FindBin::Bin/..";
  app->renderer->paths(["$root/web/templates"]);
  app->static->paths(["$root/web/public"]);

  my $dsn  = $ENV{GITMSYNCD_DSN}  || 'dbi:Pg:dbname=gitmsyncd;host=127.0.0.1;port=5432';
  my $user = $ENV{GITMSYNCD_DB_USER} || 'gitmsyncd';
  my $pass = $ENV{GITMSYNCD_DB_PASS} || 'gitmsyncd';

  helper dbh => sub {
    state $dbh = DBI->connect($dsn, $user, $pass, { RaiseError => 1, AutoCommit => 1, pg_enable_utf8 => 1 });
    return $dbh;
  };

  # ── Health ──────────────────────────────────────────────────────────
  get '/api/health' => sub ($c) {
    $c->render(json => { status => 'ok' });
  };

  # ── Mappings CRUD ──────────────────────────────────────────────────
  get '/api/mappings' => sub ($c) {
    my $rows = $c->dbh->selectall_arrayref(
      q{SELECT id, source_provider, source_full_path, target_provider, target_full_path, direction, enabled, profile_id FROM repo_mappings ORDER BY id},
      { Slice => {} }
    );
    $c->render(json => $rows);
  };

  post '/api/mappings' => sub ($c) {
    my $p = $c->req->json || {};
    $c->dbh->do(
      q{INSERT INTO repo_mappings (source_provider, source_full_path, target_provider, target_full_path, direction, enabled, profile_id)
        VALUES (?, ?, ?, ?, ?, COALESCE(?, TRUE), ?)},
      undef,
      $p->{source_provider}, $p->{source_full_path},
      $p->{target_provider}, $p->{target_full_path},
      $p->{direction}, $p->{enabled}, $p->{profile_id}
    );
    $c->render(json => { ok => Mojo::JSON->true });
  };

  put '/api/mappings/:id' => sub ($c) {
    my $id = $c->param('id');
    my $p  = $c->req->json || {};
    my @sets;
    my @vals;
    for my $k (qw(source_provider source_full_path target_provider target_full_path direction enabled profile_id)) {
      if (exists $p->{$k}) { push @sets, "$k = ?"; push @vals, $p->{$k}; }
    }
    return $c->render(json => { error => 'nothing to update' }, status => 400) unless @sets;
    push @vals, $id;
    $c->dbh->do("UPDATE repo_mappings SET " . join(', ', @sets) . " WHERE id = ?", undef, @vals);
    $c->render(json => { ok => Mojo::JSON->true });
  };

  del '/api/mappings/:id' => sub ($c) {
    my $id = $c->param('id');
    $c->dbh->do(q{DELETE FROM repo_mappings WHERE id = ?}, undef, $id);
    $c->render(json => { ok => Mojo::JSON->true });
  };

  post '/api/sync/start/:profile_id' => sub ($c) {
    my $id = $c->param('profile_id');
    $c->dbh->do(q{INSERT INTO sync_jobs (profile_id, status, started_at, message) VALUES (?, 'queued', NOW(), 'queued via API')}, undef, $id);
    $c->render(json => { ok => Mojo::JSON->true, profile_id => $id });
  };

  post '/api/sync/stop/:job_id' => sub ($c) {
    my $id = $c->param('job_id');
    $c->dbh->do(q{UPDATE sync_jobs SET status='stopped', finished_at=NOW(), message='stopped via API' WHERE id=? AND status IN ('queued','running')}, undef, $id);
    $c->render(json => { ok => Mojo::JSON->true, job_id => $id });
  };

  # ── Providers CRUD ─────────────────────────────────────────────────

  get '/api/providers' => sub ($c) {
    my $rows = $c->dbh->selectall_arrayref(
      q{SELECT id, name, provider_type, base_url, enabled, created_at, last_tested_at, test_status
        FROM providers ORDER BY id},
      { Slice => {} }
    );
    $c->render(json => $rows);
  };

  post '/api/providers' => sub ($c) {
    my $p = $c->req->json || {};
    for my $f (qw(name provider_type api_token)) {
      return $c->render(json => { error => "missing required field: $f" }, status => 400) unless $p->{$f};
    }
    eval {
      $c->dbh->do(
        q{INSERT INTO providers (name, provider_type, base_url, api_token, enabled)
          VALUES (?, ?, ?, ?, COALESCE(?, TRUE))},
        undef,
        $p->{name}, $p->{provider_type}, $p->{base_url}, $p->{api_token}, $p->{enabled}
      );
    };
    if ($@) {
      return $c->render(json => { error => "insert failed: $@" }, status => 500);
    }
    my $row = $c->dbh->selectrow_hashref(q{SELECT id, name, provider_type, base_url, enabled, created_at, test_status FROM providers WHERE name = ?}, undef, $p->{name});
    $c->render(json => $row, status => 201);
  };

  put '/api/providers/:id' => sub ($c) {
    my $id = $c->param('id');
    my $p  = $c->req->json || {};
    my $existing = $c->dbh->selectrow_hashref(q{SELECT id FROM providers WHERE id = ?}, undef, $id);
    return $c->render(json => { error => 'provider not found' }, status => 404) unless $existing;

    my @sets;
    my @vals;
    for my $col (qw(name provider_type base_url api_token enabled)) {
      if (exists $p->{$col}) {
        push @sets, "$col = ?";
        push @vals, $p->{$col};
      }
    }
    return $c->render(json => { error => 'nothing to update' }, status => 400) unless @sets;

    push @vals, $id;
    eval {
      $c->dbh->do("UPDATE providers SET " . join(', ', @sets) . " WHERE id = ?", undef, @vals);
    };
    if ($@) {
      return $c->render(json => { error => "update failed: $@" }, status => 500);
    }
    my $row = $c->dbh->selectrow_hashref(
      q{SELECT id, name, provider_type, base_url, enabled, created_at, last_tested_at, test_status FROM providers WHERE id = ?},
      undef, $id
    );
    $c->render(json => $row);
  };

  del '/api/providers/:id' => sub ($c) {
    my $id = $c->param('id');
    my $existing = $c->dbh->selectrow_hashref(q{SELECT id FROM providers WHERE id = ?}, undef, $id);
    return $c->render(json => { error => 'provider not found' }, status => 404) unless $existing;
    $c->dbh->do(q{DELETE FROM providers WHERE id = ?}, undef, $id);
    $c->render(json => { ok => Mojo::JSON->true });
  };

  # ── Provider connectivity test ─────────────────────────────────────

  post '/api/providers/:id/test' => sub ($c) {
    my $id  = $c->param('id');
    my $row = $c->dbh->selectrow_hashref(
      q{SELECT id, provider_type, base_url, api_token FROM providers WHERE id = ?},
      undef, $id
    );
    return $c->render(json => { error => 'provider not found' }, status => 404) unless $row;

    my ($url, %headers);
    my $type = $row->{provider_type};

    if ($type eq 'github') {
      $url = 'https://api.github.com/user';
      %headers = (
        'Authorization' => "Bearer $row->{api_token}",
        'Accept'        => 'application/vnd.github+json',
        'User-Agent'    => 'gitmsyncd/1.0',
      );
    } elsif ($type eq 'gitlab') {
      my $base = $row->{base_url} || 'https://gitlab.com';
      $base =~ s{/+$}{};
      $url = "$base/api/v4/user";
      %headers = ('PRIVATE-TOKEN' => $row->{api_token});
    } elsif ($type eq 'gitea') {
      my $base = $row->{base_url} || 'https://gitea.com';
      $base =~ s{/+$}{};
      $url = "$base/api/v1/user";
      %headers = ('Authorization' => "token $row->{api_token}");
    }

    my $ua  = Mojo::UserAgent->new;
    $ua->connect_timeout(10);
    $ua->request_timeout(15);
    my $tx  = $ua->get($url => \%headers);
    my $res = $tx->result;

    my ($status, $message);
    if ($res && $res->is_success) {
      $status  = 'ok';
      my $body = eval { $res->json } || {};
      $message = "authenticated as: " . ($body->{login} || $body->{username} || $body->{name} || 'unknown');
    } else {
      $status  = 'failed';
      $message = $res ? "HTTP " . $res->code . ": " . ($res->message || 'error') : "connection failed: " . ($tx->error->{message} || 'unknown');
    }

    $c->dbh->do(
      q{UPDATE providers SET last_tested_at = NOW(), test_status = ? WHERE id = ?},
      undef, $status, $id
    );

    $c->render(json => { provider_id => $id, test_status => $status, message => $message });
  };

  # ── Profiles CRUD ──────────────────────────────────────────────────

  get '/api/profiles' => sub ($c) {
    my $rows = $c->dbh->selectall_arrayref(
      q{SELECT sp.id, sp.name, sp.direction, sp.source_owner, sp.target_owner,
               sp.source_provider_id, sp.target_provider_id,
               sp.conflict_policy, sp.enabled, sp.created_at,
               sp.sync_interval_minutes, sp.next_sync_at, sp.last_synced_at,
               src.name AS source_provider_name, src.provider_type AS source_provider_type,
               tgt.name AS target_provider_name, tgt.provider_type AS target_provider_type
        FROM sync_profiles sp
        LEFT JOIN providers src ON sp.source_provider_id = src.id
        LEFT JOIN providers tgt ON sp.target_provider_id = tgt.id
        ORDER BY sp.id},
      { Slice => {} }
    );
    $c->render(json => $rows);
  };

  post '/api/profiles' => sub ($c) {
    my $p = $c->req->json || {};
    for my $f (qw(name direction source_owner target_owner)) {
      return $c->render(json => { error => "missing required field: $f" }, status => 400) unless $p->{$f};
    }
    # Block same provider + same org (would sync repo to itself)
    if ($p->{source_provider_id} && $p->{target_provider_id}
        && $p->{source_provider_id} eq $p->{target_provider_id}
        && $p->{source_owner} eq $p->{target_owner}) {
      return $c->render(json => { error => "Source and target are the same provider and org — this would sync a repo to itself." }, status => 400);
    }
    eval {
      # Calculate staggered next_sync_at if interval is set
      my $interval = $p->{sync_interval_minutes};
      my $next_sync = undef;
      if ($interval && $interval > 0) {
        my $stagger = int(rand($interval * 60)); # random offset in seconds
        $next_sync = strftime('%Y-%m-%d %H:%M:%S', localtime(time + $stagger));
      }
      $c->dbh->do(
        q{INSERT INTO sync_profiles (name, direction, source_owner, target_owner, source_provider_id, target_provider_id, conflict_policy, enabled, sync_interval_minutes, next_sync_at)
          VALUES (?, ?, ?, ?, ?, ?, COALESCE(?, 'ff-only'), COALESCE(?, TRUE), ?, ?)},
        undef,
        $p->{name}, $p->{direction}, $p->{source_owner}, $p->{target_owner},
        $p->{source_provider_id}, $p->{target_provider_id},
        $p->{conflict_policy}, $p->{enabled}, $interval, $next_sync
      );
    };
    if ($@) {
      return $c->render(json => { error => "insert failed: $@" }, status => 500);
    }
    my $row = $c->dbh->selectrow_hashref(q{SELECT id, name, direction, source_owner, target_owner, source_provider_id, target_provider_id, conflict_policy, enabled FROM sync_profiles WHERE name = ?}, undef, $p->{name});
    $c->render(json => $row, status => 201);
  };

  put '/api/profiles/:id' => sub ($c) {
    my $id = $c->param('id');
    my $p  = $c->req->json || {};
    my $existing = $c->dbh->selectrow_hashref(q{SELECT id FROM sync_profiles WHERE id = ?}, undef, $id);
    return $c->render(json => { error => 'profile not found' }, status => 404) unless $existing;
    my @sets;
    my @vals;
    for my $k (qw(name direction source_owner target_owner source_provider_id target_provider_id conflict_policy enabled sync_interval_minutes)) {
      if (exists $p->{$k}) { push @sets, "$k = ?"; push @vals, $p->{$k}; }
    }
    # If interval changed, recalculate next_sync_at
    if (exists $p->{sync_interval_minutes}) {
      my $interval = $p->{sync_interval_minutes};
      if ($interval && $interval > 0) {
        my $stagger = int(rand(60)); # small random offset
        my $next = strftime('%Y-%m-%d %H:%M:%S', localtime(time + $stagger));
        push @sets, "next_sync_at = ?";
        push @vals, $next;
      } else {
        push @sets, "next_sync_at = NULL";
      }
    }
    return $c->render(json => { error => 'nothing to update' }, status => 400) unless @sets;
    push @vals, $id;
    $c->dbh->do("UPDATE sync_profiles SET " . join(', ', @sets) . " WHERE id = ?", undef, @vals);
    $c->render(json => { ok => Mojo::JSON->true });
  };

  del '/api/profiles/:id' => sub ($c) {
    my $id = $c->param('id');
    my $existing = $c->dbh->selectrow_hashref(q{SELECT id FROM sync_profiles WHERE id = ?}, undef, $id);
    return $c->render(json => { error => 'profile not found' }, status => 404) unless $existing;
    $c->dbh->do(q{DELETE FROM sync_profiles WHERE id = ?}, undef, $id);
    $c->render(json => { ok => Mojo::JSON->true });
  };

  # ── Repo discovery from provider API ───────────────────────────────

  get '/api/providers/:id/repos' => sub ($c) {
    my $id    = $c->param('id');
    my $owner = $c->param('owner');
    my $prov  = $c->dbh->selectrow_hashref(
      q{SELECT id, provider_type, base_url, api_token FROM providers WHERE id = ?},
      undef, $id
    );
    return $c->render(json => { error => 'provider not found' }, status => 404) unless $prov;
    return $c->render(json => { error => 'owner query param required (e.g. ?owner=myorg)' }, status => 400) unless $owner;

    my ($url, %headers);
    my $type = $prov->{provider_type};

    if ($type eq 'github') {
      $url = "https://api.github.com/orgs/$owner/repos?per_page=100";
      %headers = (
        'Authorization' => "Bearer $prov->{api_token}",
        'Accept'        => 'application/vnd.github+json',
        'User-Agent'    => 'gitmsyncd/1.0',
      );
    } elsif ($type eq 'gitlab') {
      my $base = $prov->{base_url} || 'https://gitlab.com';
      $base =~ s{/+$}{};
      $url = "$base/api/v4/groups/$owner/projects?per_page=100&include_subgroups=true";
      %headers = ('PRIVATE-TOKEN' => $prov->{api_token});
    } elsif ($type eq 'gitea') {
      my $base = $prov->{base_url} || 'https://gitea.com';
      $base =~ s{/+$}{};
      $url = "$base/api/v1/orgs/$owner/repos?limit=50";
      %headers = ('Authorization' => "token $prov->{api_token}");
    }

    my $ua = Mojo::UserAgent->new;
    $ua->connect_timeout(10);
    $ua->request_timeout(30);
    my $tx  = $ua->get($url => \%headers);
    my $res = $tx->result;

    unless ($res && $res->is_success) {
      my $msg = $res ? "HTTP " . $res->code . ": " . ($res->message || 'error') : "connection failed: " . ($tx->error->{message} || 'unknown');
      return $c->render(json => { error => $msg }, status => 502);
    }

    my $body = eval { $res->json } || [];
    my @repos;
    for my $r (@$body) {
      if ($type eq 'github' || $type eq 'gitea') {
        push @repos, {
          name      => $r->{name},
          full_name => $r->{full_name},
          clone_url => $r->{clone_url},
          private   => $r->{private} ? Mojo::JSON->true : Mojo::JSON->false,
        };
      } elsif ($type eq 'gitlab') {
        push @repos, {
          name      => $r->{name},
          full_name => $r->{path_with_namespace},
          clone_url => $r->{http_url_to_repo},
          private   => ($r->{visibility} eq 'private') ? Mojo::JSON->true : Mojo::JSON->false,
        };
      }
    }

    $c->render(json => { provider_id => $id, owner => $owner, count => scalar(@repos), repos => \@repos });
  };

  # ── Sync engine ────────────────────────────────────────────────────

  post '/api/sync/run/:profile_id' => sub ($c) {
    my $profile_id = $c->param('profile_id');

    # Load profile with provider details
    my $profile = $c->dbh->selectrow_hashref(
      q{SELECT sp.*, src.provider_type AS src_type, src.base_url AS src_base_url, src.api_token AS src_token,
               tgt.provider_type AS tgt_type, tgt.base_url AS tgt_base_url, tgt.api_token AS tgt_token
        FROM sync_profiles sp
        LEFT JOIN providers src ON sp.source_provider_id = src.id
        LEFT JOIN providers tgt ON sp.target_provider_id = tgt.id
        WHERE sp.id = ?},
      undef, $profile_id
    );
    return $c->render(json => { error => 'profile not found' }, status => 404) unless $profile;
    return $c->render(json => { error => 'profile has no source_provider_id' }, status => 400) unless $profile->{source_provider_id};
    return $c->render(json => { error => 'profile has no target_provider_id' }, status => 400) unless $profile->{target_provider_id};

    # Create the sync job
    $c->dbh->do(
      q{INSERT INTO sync_jobs (profile_id, status, started_at, message) VALUES (?, 'running', NOW(), 'started via sync/run API')},
      undef, $profile_id
    );
    my $job_id = $c->dbh->last_insert_id(undef, undef, 'sync_jobs', 'id');

    # Helper to log events
    my $log_event = sub {
      my ($level, $msg) = @_;
      $c->dbh->do(
        q{INSERT INTO sync_job_events (job_id, level, message) VALUES (?, ?, ?)},
        undef, $job_id, $level, $msg
      );
    };

    # Get repo mappings for this profile (match by source/target owner)
    my $mappings = $c->dbh->selectall_arrayref(
      q{SELECT id, source_full_path, target_full_path, direction, enabled
        FROM repo_mappings
        WHERE enabled = TRUE
        ORDER BY id},
      { Slice => {} }
    );

    # Filter mappings to those matching this profile's owners
    my @active_mappings;
    for my $m (@$mappings) {
      my $src_owner = (split('/', $m->{source_full_path}))[0] || '';
      my $tgt_owner = (split('/', $m->{target_full_path}))[0] || '';
      if ($src_owner eq $profile->{source_owner} || $tgt_owner eq $profile->{target_owner}) {
        push @active_mappings, $m;
      }
    }

    unless (@active_mappings) {
      $log_event->('warn', 'no active repo mappings found for this profile');
      $c->dbh->do(q{UPDATE sync_jobs SET status='success', finished_at=NOW(), message='no mappings to sync' WHERE id=?}, undef, $job_id);
      return $c->render(json => { job_id => $job_id, status => 'success', message => 'no mappings to sync', repos_synced => 0 });
    }

    $log_event->('info', "found " . scalar(@active_mappings) . " repo mapping(s) to sync");

    # Build clone URLs based on provider type
    my $build_url = sub {
      my ($type, $base_url, $token, $full_path) = @_;
      if ($type eq 'github') {
        return "https://$token\@github.com/$full_path.git";
      } elsif ($type eq 'gitlab') {
        my $base = $base_url || 'https://gitlab.com';
        $base =~ s{/+$}{};
        if ($base =~ m{^(https?)://(.+)}) {
          my ($scheme, $host) = ($1, $2);
          return "$scheme://oauth2:$token\@$host/$full_path.git";
        }
        return "https://oauth2:$token\@$base/$full_path.git";
      } elsif ($type eq 'gitea') {
        my $base = $base_url || 'https://gitea.com';
        $base =~ s{/+$}{};
        # Preserve http/https from the base_url
        if ($base =~ m{^(https?)://(.+)}) {
          my ($scheme, $host) = ($1, $2);
          return "$scheme://$token\@$host/$full_path.git";
        }
        return "https://$token\@$base/$full_path.git";
      }
      return undef;
    };

    my $workdir = '/tmp/gitmsyncd-workdir';
    make_path($workdir) unless -d $workdir;

    my $synced   = 0;
    my $failed   = 0;
    my $job_ok   = 1;

    for my $m (@active_mappings) {
      my $src_url = $build_url->($profile->{src_type}, $profile->{src_base_url}, $profile->{src_token}, $m->{source_full_path});
      my $tgt_url = $build_url->($profile->{tgt_type}, $profile->{tgt_base_url}, $profile->{tgt_token}, $m->{target_full_path});

      unless ($src_url && $tgt_url) {
        $log_event->('error', "cannot build URLs for mapping $m->{id}: $m->{source_full_path} -> $m->{target_full_path}");
        $failed++;
        next;
      }

      # Sanitize directory name
      (my $dir_name = $m->{source_full_path}) =~ s{/}{--}g;
      my $repo_dir = File::Spec->catdir($workdir, "$dir_name.git");

      $log_event->('info', "syncing $m->{source_full_path} -> $m->{target_full_path}");

      # Clone mirror from source
      rmtree($repo_dir) if -d $repo_dir;
      my $clone_out = `git clone --mirror '$src_url' '$repo_dir' 2>&1`;
      my $clone_rc  = $?;

      if ($clone_rc != 0) {
        $log_event->('error', "clone failed for $m->{source_full_path}: $clone_out");
        $failed++;
        $job_ok = 0;
        next;
      }

      # Push mirror to target
      my $push_out = `cd '$repo_dir' && git push --mirror '$tgt_url' 2>&1`;
      my $push_rc  = $?;

      if ($push_rc != 0) {
        $log_event->('error', "push failed for $m->{target_full_path}: $push_out");
        $failed++;
        $job_ok = 0;
      } else {
        $log_event->('info', "synced $m->{source_full_path} -> $m->{target_full_path} successfully");
        $synced++;
      }

      # Cleanup
      rmtree($repo_dir) if -d $repo_dir;
    }

    my $final_status  = $job_ok ? 'success' : ($synced > 0 ? 'success' : 'failed');
    my $final_message = "synced=$synced failed=$failed total=" . scalar(@active_mappings);

    $c->dbh->do(
      q{UPDATE sync_jobs SET status=?, finished_at=NOW(), message=? WHERE id=?},
      undef, $final_status, $final_message, $job_id
    );
    $log_event->('info', "job finished: $final_message");

    $c->render(json => {
      job_id       => $job_id,
      status       => $final_status,
      repos_synced => $synced,
      repos_failed => $failed,
      message      => $final_message,
    });
  };

  # ── Sync jobs listing ──────────────────────────────────────────────

  get '/api/sync/jobs' => sub ($c) {
    my $limit = $c->param('limit') || 25;
    my $rows = $c->dbh->selectall_arrayref(
      q{SELECT sj.id, sj.profile_id, sp.name AS profile_name, sj.status, sj.started_at, sj.finished_at, sj.message
        FROM sync_jobs sj
        LEFT JOIN sync_profiles sp ON sj.profile_id = sp.id
        ORDER BY sj.id DESC LIMIT ?},
      { Slice => {} }, $limit
    );
    # Attach event counts
    for my $r (@$rows) {
      my ($cnt) = $c->dbh->selectrow_array(q{SELECT COUNT(*) FROM sync_job_events WHERE job_id = ?}, undef, $r->{id});
      $r->{event_count} = $cnt;
    }
    $c->render(json => $rows);
  };

  get '/api/sync/jobs/:id' => sub ($c) {
    my $id  = $c->param('id');
    my $job = $c->dbh->selectrow_hashref(
      q{SELECT sj.id, sj.profile_id, sp.name AS profile_name, sj.status, sj.started_at, sj.finished_at, sj.message
        FROM sync_jobs sj
        LEFT JOIN sync_profiles sp ON sj.profile_id = sp.id
        WHERE sj.id = ?},
      undef, $id
    );
    return $c->render(json => { error => 'job not found' }, status => 404) unless $job;

    my $events = $c->dbh->selectall_arrayref(
      q{SELECT id, level, event_at, message FROM sync_job_events WHERE job_id = ? ORDER BY id},
      { Slice => {} }, $id
    );
    $job->{events} = $events;
    $c->render(json => $job);
  };

  # ── Web UI Pages ───────────────────────────────────────────────────

  get '/' => sub ($c) {
    my $providers = $c->dbh->selectall_arrayref(q{SELECT * FROM providers ORDER BY id}, { Slice => {} });
    my $profiles = $c->dbh->selectall_arrayref(q{SELECT sp.*, s.name as source_name, t.name as target_name FROM sync_profiles sp LEFT JOIN providers s ON sp.source_provider_id = s.id LEFT JOIN providers t ON sp.target_provider_id = t.id ORDER BY sp.id}, { Slice => {} });
    my $jobs = $c->dbh->selectall_arrayref(q{SELECT sj.*, sp.name as profile_name FROM sync_jobs sj LEFT JOIN sync_profiles sp ON sj.profile_id = sp.id ORDER BY sj.id DESC LIMIT 10}, { Slice => {} });
    $c->stash(providers => $providers, profiles => $profiles, jobs => $jobs);
    $c->render(template => 'index');
  };

  get '/providers' => sub ($c) {
    my $providers = $c->dbh->selectall_arrayref(q{SELECT * FROM providers ORDER BY id}, { Slice => {} });
    $c->stash(providers => $providers);
    $c->render(template => 'providers');
  };

  get '/profiles' => sub ($c) {
    my $profiles = $c->dbh->selectall_arrayref(q{SELECT sp.*, s.name as source_name, t.name as target_name FROM sync_profiles sp LEFT JOIN providers s ON sp.source_provider_id = s.id LEFT JOIN providers t ON sp.target_provider_id = t.id ORDER BY sp.id}, { Slice => {} });
    my $providers = $c->dbh->selectall_arrayref(q{SELECT id, name, provider_type FROM providers WHERE enabled ORDER BY name}, { Slice => {} });
    $c->stash(profiles => $profiles, providers => $providers);
    $c->render(template => 'profiles');
  };

  get '/mappings' => sub ($c) {
    my $profiles = $c->dbh->selectall_arrayref(q{SELECT id, name FROM sync_profiles ORDER BY name}, { Slice => {} });
    my $mappings = $c->dbh->selectall_arrayref(q{SELECT rm.*, sp.name as profile_name FROM repo_mappings rm LEFT JOIN sync_profiles sp ON rm.profile_id = sp.id ORDER BY rm.id DESC LIMIT 100}, { Slice => {} });
    $c->stash(profiles => $profiles, mappings => $mappings);
    $c->render(template => 'mappings');
  };

  get '/jobs' => sub ($c) {
    my $jobs = $c->dbh->selectall_arrayref(q{SELECT sj.*, sp.name as profile_name FROM sync_jobs sj LEFT JOIN sync_profiles sp ON sj.profile_id = sp.id ORDER BY sj.id DESC LIMIT 50}, { Slice => {} });
    $c->stash(jobs => $jobs);
    $c->render(template => 'jobs');
  };

  # ── Sync Engine (shared by queue worker and direct run) ─────────

  my $run_sync_job = sub {
    my ($dbh, $job_id, $profile_id) = @_;

    $dbh->do(q{UPDATE sync_jobs SET status='running', message='picked up by worker' WHERE id=?}, undef, $job_id);

    my $log_event = sub {
      my ($level, $msg) = @_;
      eval { $dbh->do(q{INSERT INTO sync_job_events (job_id, level, message) VALUES (?, ?, ?)}, undef, $job_id, $level, $msg); };
    };

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

    my $workdir = '/tmp/gitmsyncd-workdir';
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

    for my $m (@mappings) {
      my $src_url = $build_url->($profile->{src_type}, $profile->{src_base_url}, $profile->{src_token}, $m->{source_full_path}, $src_proto);
      my $tgt_url = $build_url->($profile->{tgt_type}, $profile->{tgt_base_url}, $profile->{tgt_token}, $m->{target_full_path}, $tgt_proto);

      unless ($src_url && $tgt_url) {
        $log_event->('error', "cannot build URLs for $m->{source_full_path}");
        $failed++; next;
      }

      (my $dir_name = $m->{source_full_path}) =~ s{/}{--}g;
      my $repo_dir = File::Spec->catdir($workdir, "$dir_name.git");

      $log_event->('info', "syncing $m->{source_full_path} -> $m->{target_full_path} [$src_proto/$tgt_proto]");

      rmtree($repo_dir) if -d $repo_dir;
      my $clone_cmd = $src_ssh_cmd ? "$src_ssh_cmd git clone --mirror '$src_url' '$repo_dir' 2>&1" : "git clone --mirror '$src_url' '$repo_dir' 2>&1";
      my $clone_out = `$clone_cmd`;
      if ($? != 0) {
        $log_event->('error', "clone failed for $m->{source_full_path}: $clone_out");
        $failed++; next;
      }

      my $push_cmd = $tgt_ssh_cmd ? "cd '$repo_dir' && $tgt_ssh_cmd git push --mirror '$tgt_url' 2>&1" : "cd '$repo_dir' && git push --mirror '$tgt_url' 2>&1";
      my $push_out = `$push_cmd`;
      if ($? != 0) {
        $log_event->('error', "push failed for $m->{target_full_path}: $push_out");
        $failed++;
      } else {
        $log_event->('info', "synced $m->{source_full_path} -> $m->{target_full_path} successfully");
        $synced++;
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

  # ── Queue Worker + Scheduler — runs every 5 seconds ───────────
  Mojo::IOLoop->recurring(5 => sub {
    my $dbh = DBI->connect($dsn, $user, $pass, { RaiseError => 1, AutoCommit => 1, pg_enable_utf8 => 1 });

    # 1. Process queued jobs (manual triggers)
    my $job = $dbh->selectrow_hashref(
      q{SELECT id, profile_id FROM sync_jobs WHERE status = 'queued' ORDER BY id LIMIT 1}
    );
    if ($job) {
      $run_sync_job->($dbh, $job->{id}, $job->{profile_id});
      $dbh->disconnect;
      return;  # one job per tick, don't stack
    }

    # 2. Check for scheduled profiles that are due
    my $due_profile = $dbh->selectrow_hashref(
      q{SELECT id FROM sync_profiles
        WHERE enabled = TRUE
          AND sync_interval_minutes IS NOT NULL
          AND sync_interval_minutes > 0
          AND next_sync_at IS NOT NULL
          AND next_sync_at <= NOW()
        ORDER BY next_sync_at ASC
        LIMIT 1}
    );
    if ($due_profile) {
      my $pid = $due_profile->{id};

      # Create the job
      $dbh->do(q{INSERT INTO sync_jobs (profile_id, status, started_at, message) VALUES (?, 'running', NOW(), 'scheduled sync')}, undef, $pid);
      my $job_id = $dbh->last_insert_id(undef, undef, 'sync_jobs', 'id');

      # Bump next_sync_at BEFORE running (prevents re-trigger if sync takes longer than interval)
      $dbh->do(q{UPDATE sync_profiles SET next_sync_at = NOW() + (sync_interval_minutes || ' minutes')::interval WHERE id = ?}, undef, $pid);

      # Run the sync
      $run_sync_job->($dbh, $job_id, $pid);
    }

    $dbh->disconnect;
  });

  app->start('daemon', '-l', ($ENV{GITMSYNCD_LISTEN} || 'http://127.0.0.1:9097'));
}

1;
