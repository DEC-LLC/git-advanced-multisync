package Gitmsyncd::App;
use strict;
use warnings;
use Mojolicious::Lite -signatures;
use DBI;
use FindBin;
use File::Path qw(make_path rmtree);
use File::Spec;
use POSIX qw(strftime setsid);
use Digest::SHA qw(sha256_hex);
use Sys::Hostname;
use Gitmsyncd::SyncEngine qw(run_sync_job branch_matches_filter);

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

  # ── Session secret ────────────────────────────────────────────────
  app->secrets(['gitmsyncd-change-this-secret-' . ($ENV{GITMSYNCD_SECRET} || 'dev')]);

  # ── Password hashing (SHA-256 with salt — bcrypt preferred but not available as OS package) ──
  my $hash_password = sub {
    my ($password) = @_;
    my $salt = join('', map { ('a'..'z','A'..'Z','0'..'9')[int(rand(62))] } 1..16);
    my $digest = sha256_hex($salt . $password);
    return "sha256:$salt:$digest";
  };

  my $verify_password = sub {
    my ($password, $stored_hash) = @_;
    return 0 unless $stored_hash && $password;
    if ($stored_hash =~ /^sha256:([^:]+):([0-9a-f]+)$/) {
      my ($salt, $expected) = ($1, $2);
      return sha256_hex($salt . $password) eq $expected;
    }
    return 0;
  };

  # ── Admin role check (reusable) ────────────────────────────────────
  my $require_admin = sub ($c) {
    my $user = $c->stash('current_user');
    unless ($user && $user->{role} eq 'admin') {
      if ($c->req->url->path =~ m{^/api/}) {
        $c->render(json => { error => 'admin access required' }, status => 403);
      } else {
        $c->redirect_to('/');
      }
      return 0;
    }
    return 1;
  };

  # ── Public routes (no auth required) ───────────────────────────────

  # Health endpoint — accessible without authentication (monitoring)
  get '/api/health' => sub ($c) {
    $c->render(json => { status => 'ok' });
  };

  # Login page
  get '/login' => sub ($c) {
    # If already logged in, redirect to dashboard
    if ($c->session('user_id')) {
      return $c->redirect_to('/');
    }
    $c->render(template => 'login');
  };

  # Login POST
  post '/login' => sub ($c) {
    my $username = $c->param('username') // '';
    my $password = $c->param('password') // '';

    my $user = $c->dbh->selectrow_hashref(
      q{SELECT * FROM users WHERE username = ? AND enabled = TRUE}, undef, $username
    );

    if ($user && $verify_password->($password, $user->{password_hash})) {
      $c->session(user_id => $user->{id});
      $c->dbh->do(q{UPDATE users SET last_login_at = NOW() WHERE id = ?}, undef, $user->{id});
      $c->redirect_to('/');
    } else {
      $c->stash(error => 'Invalid username or password');
      $c->render(template => 'login');
    }
  };

  # Logout
  get '/logout' => sub ($c) {
    $c->session(expires => 1);
    $c->redirect_to('/login');
  };

  # ── Auth middleware — all routes below require authentication ──────
  under '/' => sub ($c) {
    my $user_id = $c->session('user_id');
    unless ($user_id) {
      if ($c->req->url->path =~ m{^/api/}) {
        $c->render(json => { error => 'authentication required' }, status => 401);
      } else {
        $c->redirect_to('/login');
      }
      return undef;
    }

    # Load user and stash for all authenticated routes
    my $user = $c->dbh->selectrow_hashref(
      q{SELECT id, username, role FROM users WHERE id = ? AND enabled = TRUE}, undef, $user_id
    );
    unless ($user) {
      $c->session(expires => 1);
      if ($c->req->url->path =~ m{^/api/}) {
        $c->render(json => { error => 'authentication required' }, status => 401);
      } else {
        $c->redirect_to('/login');
      }
      return undef;
    }

    $c->stash(current_user => $user);
    $c->stash(is_admin => ($user->{role} eq 'admin'));
    return 1;
  };

  # ── Authenticated routes below ─────────────────────────────────────

  # ── Password change ────────────────────────────────────────────────
  post '/api/users/change-password' => sub ($c) {
    my $p = $c->req->json || {};
    my $user = $c->stash('current_user');
    for my $f (qw(current_password new_password)) {
      return $c->render(json => { error => "missing required field: $f" }, status => 400) unless $p->{$f};
    }
    return $c->render(json => { error => 'new password must be at least 8 characters' }, status => 400)
      if length($p->{new_password}) < 8;

    # Verify current password
    my $row = $c->dbh->selectrow_hashref(
      q{SELECT password_hash FROM users WHERE id = ?}, undef, $user->{id});
    unless ($row && $verify_password->($p->{current_password}, $row->{password_hash})) {
      return $c->render(json => { error => 'current password is incorrect' }, status => 403);
    }

    # Set new password
    my $new_hash = $hash_password->($p->{new_password});
    $c->dbh->do(q{UPDATE users SET password_hash = ? WHERE id = ?}, undef, $new_hash, $user->{id});
    $c->render(json => { ok => Mojo::JSON->true, message => 'password changed' });
  };

  # ── Admin: reset any user's password ───────────────────────────────
  post '/api/users/:id/reset-password' => sub ($c) {
    return unless $require_admin->($c);
    my $id = $c->param('id');
    my $p = $c->req->json || {};
    return $c->render(json => { error => 'new_password required' }, status => 400) unless $p->{new_password};
    return $c->render(json => { error => 'new password must be at least 8 characters' }, status => 400)
      if length($p->{new_password}) < 8;

    my $existing = $c->dbh->selectrow_hashref(q{SELECT id FROM users WHERE id = ?}, undef, $id);
    return $c->render(json => { error => 'user not found' }, status => 404) unless $existing;

    my $new_hash = $hash_password->($p->{new_password});
    $c->dbh->do(q{UPDATE users SET password_hash = ? WHERE id = ?}, undef, $new_hash, $id);
    $c->render(json => { ok => Mojo::JSON->true, message => "password reset for user $id" });
  };

  # ── Mappings CRUD ──────────────────────────────────────────────────
  get '/api/mappings' => sub ($c) {
    my $rows = $c->dbh->selectall_arrayref(
      q{SELECT id, source_provider, source_full_path, target_provider, target_full_path, direction, enabled, profile_id, branch_filter FROM repo_mappings ORDER BY id},
      { Slice => {} }
    );
    $c->render(json => $rows);
  };

  post '/api/mappings' => sub ($c) {
    return unless $require_admin->($c);
    my $p = $c->req->json || {};

    # Check for duplicate: same source+target repo pair already synced by ANY profile
    my $existing = $c->dbh->selectrow_hashref(
      q{SELECT rm.id, rm.profile_id, sp.name AS profile_name
        FROM repo_mappings rm
        LEFT JOIN sync_profiles sp ON rm.profile_id = sp.id
        WHERE rm.source_full_path = ? AND rm.target_full_path = ?},
      undef, $p->{source_full_path}, $p->{target_full_path}
    );
    if ($existing) {
      my $owner = $existing->{profile_name} || "unassigned (mapping #$existing->{id})";
      return $c->render(json => {
        error => "This repo pair is already synced by profile \"$owner\". " .
                 "Remove it from that profile first, or use a different target path."
      }, status => 409);
    }

    # Also check reverse direction (target→source already mapped as source→target)
    my $reverse = $c->dbh->selectrow_hashref(
      q{SELECT rm.id, rm.profile_id, sp.name AS profile_name
        FROM repo_mappings rm
        LEFT JOIN sync_profiles sp ON rm.profile_id = sp.id
        WHERE rm.source_full_path = ? AND rm.target_full_path = ?},
      undef, $p->{target_full_path}, $p->{source_full_path}
    );
    if ($reverse) {
      my $owner = $reverse->{profile_name} || "unassigned (mapping #$reverse->{id})";
      return $c->render(json => {
        error => "The reverse of this repo pair is already synced by profile \"$owner\" " .
                 "(target→source). Adding this would create a sync loop."
      }, status => 409);
    }

    eval {
      $c->dbh->do(
        q{INSERT INTO repo_mappings (source_provider, source_full_path, target_provider, target_full_path, direction, enabled, profile_id, branch_filter)
          VALUES (?, ?, ?, ?, ?, COALESCE(?, TRUE), ?, ?)},
        undef,
        $p->{source_provider}, $p->{source_full_path},
        $p->{target_provider}, $p->{target_full_path},
        $p->{direction}, $p->{enabled}, $p->{profile_id}, $p->{branch_filter}
      );
    };
    if ($@) {
      return $c->render(json => { error => "insert failed: $@" }, status => 500);
    }
    $c->render(json => { ok => Mojo::JSON->true });
  };

  put '/api/mappings/:id' => sub ($c) {
    return unless $require_admin->($c);
    my $id = $c->param('id');
    my $p  = $c->req->json || {};
    my @sets;
    my @vals;
    for my $k (qw(source_provider source_full_path target_provider target_full_path direction enabled profile_id branch_filter)) {
      if (exists $p->{$k}) { push @sets, "$k = ?"; push @vals, $p->{$k}; }
    }
    return $c->render(json => { error => 'nothing to update' }, status => 400) unless @sets;
    push @vals, $id;
    $c->dbh->do("UPDATE repo_mappings SET " . join(', ', @sets) . " WHERE id = ?", undef, @vals);
    $c->render(json => { ok => Mojo::JSON->true });
  };

  del '/api/mappings/:id' => sub ($c) {
    return unless $require_admin->($c);
    my $id = $c->param('id');
    $c->dbh->do(q{DELETE FROM repo_mappings WHERE id = ?}, undef, $id);
    $c->render(json => { ok => Mojo::JSON->true });
  };

  post '/api/sync/start/:profile_id' => sub ($c) {
    return unless $require_admin->($c);
    my $id = $c->param('profile_id');

    # Prevent duplicate queue entries — check for existing queued/running jobs
    my $existing = $c->dbh->selectrow_hashref(
      q{SELECT id FROM sync_jobs WHERE profile_id = ? AND status IN ('queued', 'running')}, undef, $id);
    if ($existing) {
      return $c->render(json => { error => 'A sync job is already queued or running for this profile.' }, status => 409);
    }

    # Check if the profile is currently locked by another sync
    my $locked = $c->dbh->selectrow_hashref(
      q{SELECT sync_locked, sync_locked_by FROM sync_profiles WHERE id = ? AND sync_locked = TRUE AND sync_locked_at >= NOW() - INTERVAL '30 minutes'}, undef, $id);
    if ($locked) {
      return $c->render(json => { error => 'This profile is currently being synced by ' . ($locked->{sync_locked_by} || 'another process') . '.' }, status => 409);
    }

    $c->dbh->do(q{INSERT INTO sync_jobs (profile_id, status, started_at, message) VALUES (?, 'queued', NOW(), 'queued via API')}, undef, $id);
    $c->render(json => { ok => Mojo::JSON->true, profile_id => $id });
  };

  post '/api/sync/stop/:job_id' => sub ($c) {
    return unless $require_admin->($c);
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
    return unless $require_admin->($c);
    my $p = $c->req->json || {};
    for my $f (qw(name provider_type api_token)) {
      return $c->render(json => { error => "missing required field: $f" }, status => 400) unless $p->{$f};
    }
    eval {
      $c->dbh->do(
        q{INSERT INTO providers (name, provider_type, base_url, api_token, clone_protocol, push_protocol, ssh_key_path, enabled)
          VALUES (?, ?, ?, ?, COALESCE(?, 'https'), COALESCE(?, 'https'), ?, COALESCE(?, TRUE))},
        undef,
        $p->{name}, $p->{provider_type}, $p->{base_url}, $p->{api_token},
        $p->{clone_protocol}, $p->{push_protocol}, $p->{ssh_key_path}, $p->{enabled}
      );
    };
    if ($@) {
      return $c->render(json => { error => "insert failed: $@" }, status => 500);
    }
    my $row = $c->dbh->selectrow_hashref(q{SELECT id, name, provider_type, base_url, enabled, created_at, test_status FROM providers WHERE name = ?}, undef, $p->{name});
    $c->render(json => $row, status => 201);
  };

  put '/api/providers/:id' => sub ($c) {
    return unless $require_admin->($c);
    my $id = $c->param('id');
    my $p  = $c->req->json || {};
    my $existing = $c->dbh->selectrow_hashref(q{SELECT id FROM providers WHERE id = ?}, undef, $id);
    return $c->render(json => { error => 'provider not found' }, status => 404) unless $existing;

    my @sets;
    my @vals;
    for my $col (qw(name provider_type base_url api_token clone_protocol push_protocol ssh_key_path enabled)) {
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
    return unless $require_admin->($c);
    my $id = $c->param('id');
    my $existing = $c->dbh->selectrow_hashref(q{SELECT id FROM providers WHERE id = ?}, undef, $id);
    return $c->render(json => { error => 'provider not found' }, status => 404) unless $existing;
    $c->dbh->do(q{DELETE FROM providers WHERE id = ?}, undef, $id);
    $c->render(json => { ok => Mojo::JSON->true });
  };

  # ── Provider connectivity test ─────────────────────────────────────

  post '/api/providers/:id/test' => sub ($c) {
    return unless $require_admin->($c);
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
               sp.sync_locked, sp.sync_locked_at, sp.sync_locked_by,
               sp.worker_set_id,
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
    return unless $require_admin->($c);
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
        q{INSERT INTO sync_profiles (name, direction, source_owner, target_owner, source_provider_id, target_provider_id, conflict_policy, enabled, sync_interval_minutes, next_sync_at, worker_set_id)
          VALUES (?, ?, ?, ?, ?, ?, COALESCE(?, 'ff-only'), COALESCE(?, TRUE), ?, ?, ?)},
        undef,
        $p->{name}, $p->{direction}, $p->{source_owner}, $p->{target_owner},
        $p->{source_provider_id}, $p->{target_provider_id},
        $p->{conflict_policy}, $p->{enabled}, $interval, $next_sync, $p->{worker_set_id}
      );
    };
    if ($@) {
      return $c->render(json => { error => "insert failed: $@" }, status => 500);
    }
    my $row = $c->dbh->selectrow_hashref(q{SELECT id, name, direction, source_owner, target_owner, source_provider_id, target_provider_id, conflict_policy, enabled FROM sync_profiles WHERE name = ?}, undef, $p->{name});
    $c->render(json => $row, status => 201);
  };

  put '/api/profiles/:id' => sub ($c) {
    return unless $require_admin->($c);
    my $id = $c->param('id');
    my $p  = $c->req->json || {};
    my $existing = $c->dbh->selectrow_hashref(q{SELECT id FROM sync_profiles WHERE id = ?}, undef, $id);
    return $c->render(json => { error => 'profile not found' }, status => 404) unless $existing;
    my @sets;
    my @vals;
    for my $k (qw(name direction source_owner target_owner source_provider_id target_provider_id conflict_policy enabled sync_interval_minutes worker_set_id)) {
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
    return unless $require_admin->($c);
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

  # ── Sync engine (uses shared SyncEngine module) ────────────────────

  post '/api/sync/run/:profile_id' => sub ($c) {
    return unless $require_admin->($c);
    my $profile_id = $c->param('profile_id');

    # Create the sync job
    $c->dbh->do(
      q{INSERT INTO sync_jobs (profile_id, status, started_at, message) VALUES (?, 'running', NOW(), 'started via sync/run API')},
      undef, $profile_id
    );
    my $job_id = $c->dbh->last_insert_id(undef, undef, 'sync_jobs', 'id');

    # Run sync using shared engine
    run_sync_job(
      dbh        => $c->dbh,
      job_id     => $job_id,
      profile_id => $profile_id,
      workdir    => $ENV{GITMSYNCD_WORKDIR} || '/tmp/gitmsyncd-workdir',
    );

    # Return result
    my $job = $c->dbh->selectrow_hashref(
      q{SELECT id, status, message FROM sync_jobs WHERE id = ?}, undef, $job_id
    );
    $c->render(json => $job);
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

  get '/status' => sub ($c) {
    # System stats
    my $providers = $c->dbh->selectrow_hashref(q{SELECT count(*) as total, count(*) FILTER (WHERE test_status = 'ok') as ok FROM providers WHERE enabled});
    my $profiles = $c->dbh->selectrow_hashref(q{SELECT count(*) as total, count(*) FILTER (WHERE enabled) as enabled, count(*) FILTER (WHERE sync_interval_minutes > 0) as scheduled FROM sync_profiles});
    my $jobs = $c->dbh->selectrow_hashref(q{SELECT count(*) as total, count(*) FILTER (WHERE status = 'success') as success, count(*) FILTER (WHERE status = 'failed') as failed, count(*) FILTER (WHERE status = 'queued') as queued, count(*) FILTER (WHERE status = 'running') as running FROM sync_jobs});
    my $mappings = $c->dbh->selectrow_hashref(q{SELECT count(*) as total, count(*) FILTER (WHERE enabled) as enabled FROM repo_mappings});
    my $users = $c->dbh->selectall_arrayref(q{SELECT id, username, role, enabled, last_login_at FROM users ORDER BY id}, { Slice => {} });
    my $next_syncs = $c->dbh->selectall_arrayref(q{SELECT sp.name, sp.sync_interval_minutes, sp.next_sync_at, sp.last_synced_at, sp.sync_locked, sp.sync_locked_by FROM sync_profiles sp WHERE sp.enabled AND sp.sync_interval_minutes > 0 ORDER BY sp.next_sync_at ASC NULLS LAST LIMIT 10}, { Slice => {} });
    my $recent_jobs = $c->dbh->selectall_arrayref(q{SELECT sj.id, sj.status, sj.started_at, sj.finished_at, sj.message, sp.name as profile_name FROM sync_jobs sj LEFT JOIN sync_profiles sp ON sj.profile_id = sp.id ORDER BY sj.id DESC LIMIT 5}, { Slice => {} });

    my $workers = $c->dbh->selectall_arrayref(q{
      SELECT *, CASE WHEN last_heartbeat_at >= NOW() - INTERVAL '30 seconds' THEN 'healthy'
                     WHEN last_heartbeat_at >= NOW() - INTERVAL '2 minutes' THEN 'stale'
                     ELSE 'dead' END AS health
      FROM workers WHERE status != 'stopped' ORDER BY started_at DESC
    }, { Slice => {} });

    # Workdir size
    my $status_workdir = $ENV{GITMSYNCD_WORKDIR} || '/tmp/gitmsyncd-workdir';
    my $workdir_size = `du -sh '$status_workdir' 2>/dev/null | cut -f1` || '0';
    chomp $workdir_size;

    # DB size
    my $db_size = $c->dbh->selectrow_hashref(q{SELECT pg_size_pretty(pg_database_size('gitmsyncd')) as size});

    $c->stash(
      providers => $providers, profiles => $profiles, jobs_stats => $jobs,
      mappings => $mappings, users => $users, next_syncs => $next_syncs,
      recent_jobs => $recent_jobs, workers => $workers,
      workdir_size => $workdir_size,
      db_size => $db_size->{size}, start_time => $^T,
    );
    $c->render(template => 'status');
  };

  # ── Workers API ────────────────────────────────────────────────────

  get '/api/workers' => sub ($c) {
    my $rows = $c->dbh->selectall_arrayref(
      q{SELECT id, worker_set, hostname, pid, status, active_forks, started_at, last_heartbeat_at,
               CASE WHEN last_heartbeat_at >= NOW() - INTERVAL '30 seconds' THEN 'healthy'
                    WHEN last_heartbeat_at >= NOW() - INTERVAL '2 minutes' THEN 'stale'
                    ELSE 'dead' END AS health
        FROM workers ORDER BY started_at DESC},
      { Slice => {} }
    );
    $c->render(json => $rows);
  };

  # ── Worker Sets CRUD ──────────────────────────────────────────────

  get '/api/worker-sets' => sub ($c) {
    my $rows = $c->dbh->selectall_arrayref(
      q{SELECT ws.*, (SELECT count(*) FROM sync_profiles sp WHERE sp.worker_set_id = ws.id) AS profile_count
        FROM worker_sets ws ORDER BY ws.id},
      { Slice => {} }
    );
    $c->render(json => $rows);
  };

  post '/api/worker-sets' => sub ($c) {
    return unless $require_admin->($c);
    my $p = $c->req->json || {};
    return $c->render(json => { error => 'name required' }, status => 400) unless $p->{name};
    eval {
      $c->dbh->do(q{INSERT INTO worker_sets (name, max_forks_per_worker, enabled)
                     VALUES (?, COALESCE(?, 4), COALESCE(?, TRUE))},
        undef, $p->{name}, $p->{max_forks_per_worker}, $p->{enabled});
    };
    return $c->render(json => { error => "insert failed: $@" }, status => 500) if $@;
    my $row = $c->dbh->selectrow_hashref(q{SELECT * FROM worker_sets WHERE name = ?}, undef, $p->{name});
    $c->render(json => $row, status => 201);
  };

  del '/api/worker-sets/:id' => sub ($c) {
    return unless $require_admin->($c);
    $c->dbh->do(q{DELETE FROM worker_sets WHERE id = ?}, undef, $c->param('id'));
    $c->render(json => { ok => Mojo::JSON->true });
  };

  # ── Worker lifecycle: spawn helper ────────────────────────────
  my $worker_script = "$root/bin/gitmsyncd-worker.pl";

  my $spawn_worker = sub {
    my ($set) = @_;
    $set ||= 'default';

    # Double-fork to fully detach worker from web process
    my $pid = fork();
    return unless defined $pid;
    if ($pid == 0) {
      # First child: detach session, fork again, exit
      setsid();
      my $grandchild = fork();
      if ($grandchild) {
        exit 0;  # first child exits immediately
      }
      # Grandchild: exec the worker (fully detached from web)
      exec('perl', $worker_script, '--set=' . $set);
      exit 1;  # exec failed
    }
    waitpid($pid, 0);  # reap first child immediately (it exits fast)
    return 1;
  };

  # ── Worker lifecycle API ──────────────────────────────────────

  # Start a new worker for a set
  post '/api/workers/start' => sub ($c) {
    return unless $require_admin->($c);
    my $p = $c->req->json || {};
    my $set = $p->{set} || 'default';

    $spawn_worker->($set);
    # Worker will self-register in the workers table within ~5 seconds
    $c->render(json => { ok => Mojo::JSON->true, set => $set, message => "worker starting for set '$set'" });
  };

  # Stop a worker (sends SIGTERM via PID from DB)
  post '/api/workers/:id/stop' => sub ($c) {
    return unless $require_admin->($c);
    my $id = $c->param('id');
    my $w = $c->dbh->selectrow_hashref(
      q{SELECT id, pid, hostname, status FROM workers WHERE id = ?}, undef, $id);
    return $c->render(json => { error => 'worker not found' }, status => 404) unless $w;

    my $this_host = hostname();
    if ($w->{hostname} ne $this_host) {
      # Remote worker — set status flag, worker will see it on next heartbeat check
      $c->dbh->do(q{UPDATE workers SET status = 'stopped' WHERE id = ?}, undef, $id);
      return $c->render(json => { ok => Mojo::JSON->true, method => 'flag',
        message => "stop flag set for remote worker on $w->{hostname} (will stop on next poll)" });
    }

    # Local worker — send SIGTERM directly
    if ($w->{pid} && kill(0, $w->{pid})) {
      kill 'TERM', $w->{pid};
      $c->dbh->do(q{UPDATE workers SET status = 'stopping' WHERE id = ?}, undef, $id);
      $c->render(json => { ok => Mojo::JSON->true, method => 'signal', pid => $w->{pid} });
    } else {
      $c->dbh->do(q{UPDATE workers SET status = 'dead' WHERE id = ?}, undef, $id);
      $c->render(json => { ok => Mojo::JSON->true, method => 'already_dead' });
    }
  };

  # Pause a worker (stops picking up new work, finishes current jobs)
  post '/api/workers/:id/pause' => sub ($c) {
    return unless $require_admin->($c);
    my $id = $c->param('id');
    $c->dbh->do(q{UPDATE workers SET paused = TRUE WHERE id = ?}, undef, $id);
    $c->render(json => { ok => Mojo::JSON->true, message => 'worker will pause on next poll cycle' });
  };

  # Resume a paused worker
  post '/api/workers/:id/resume' => sub ($c) {
    return unless $require_admin->($c);
    my $id = $c->param('id');
    $c->dbh->do(q{UPDATE workers SET paused = FALSE, status = 'running' WHERE id = ?}, undef, $id);
    $c->render(json => { ok => Mojo::JSON->true, message => 'worker resumed' });
  };

  # ── Auto-start workers on boot ───────────────────────────────
  # Spawn a worker for each enabled set (and a default worker if no sets exist)
  # Disabled via GITMSYNCD_NO_AUTOSTART=1 (used by test harness)
  Mojo::IOLoop->next_tick(sub {
    return if $ENV{GITMSYNCD_NO_AUTOSTART};
    my $boot_dbh = DBI->connect($dsn, $user, $pass, { RaiseError => 1, AutoCommit => 1, pg_enable_utf8 => 1 });

    # Mark any stale workers from previous run as dead
    $boot_dbh->do(q{UPDATE workers SET status = 'dead'
                     WHERE hostname = ? AND status IN ('running', 'paused')
                       AND last_heartbeat_at < NOW() - INTERVAL '2 minutes'},
      undef, hostname());

    # Get enabled worker sets
    my $sets = $boot_dbh->selectall_arrayref(
      q{SELECT name FROM worker_sets WHERE enabled = TRUE}, { Slice => {} });

    if (@$sets) {
      for my $ws (@$sets) {
        print "[boot] auto-starting worker for set '$ws->{name}'\n";
        $spawn_worker->($ws->{name});
      }
    } else {
      # No sets configured — start a default worker
      print "[boot] no worker sets configured, starting default worker\n";
      $spawn_worker->('default');
    }

    $boot_dbh->disconnect;
  });

  app->start('daemon', '-l', ($ENV{GITMSYNCD_LISTEN} || 'http://127.0.0.1:9097'));
}

1;
