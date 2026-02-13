package Gitmsyncd::App;
use strict;
use warnings;
use Mojolicious::Lite -signatures;
use DBI;

sub start {
  my ($self) = @_;

  my $dsn  = $ENV{GITMSYNCD_DSN}  || 'dbi:Pg:dbname=gitmsyncd;host=127.0.0.1;port=5432';
  my $user = $ENV{GITMSYNCD_DB_USER} || 'gitmsyncd';
  my $pass = $ENV{GITMSYNCD_DB_PASS} || 'gitmsyncd';

  helper dbh => sub {
    state $dbh = DBI->connect($dsn, $user, $pass, { RaiseError => 1, AutoCommit => 1, pg_enable_utf8 => 1 });
    return $dbh;
  };

  # API
  get '/api/health' => sub ($c) {
    $c->render(json => { status => 'ok' });
  };

  get '/api/mappings' => sub ($c) {
    my $rows = $c->dbh->selectall_arrayref(
      q{SELECT id, source_full_path, target_full_path, direction, enabled FROM repo_mappings ORDER BY id},
      { Slice => {} }
    );
    $c->render(json => $rows);
  };

  post '/api/mappings' => sub ($c) {
    my $p = $c->req->json || {};
    $c->dbh->do(
      q{INSERT INTO repo_mappings (source_provider, source_full_path, target_provider, target_full_path, direction, enabled)
        VALUES (?, ?, ?, ?, ?, COALESCE(?, TRUE))},
      undef,
      $p->{source_provider}, $p->{source_full_path},
      $p->{target_provider}, $p->{target_full_path},
      $p->{direction}, $p->{enabled}
    );
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

  # Minimal UI
  get '/' => sub ($c) {
    my $profiles = $c->dbh->selectall_arrayref(q{SELECT id, name, direction, enabled FROM sync_profiles ORDER BY id}, { Slice => {} });
    my $mappings = $c->dbh->selectall_arrayref(q{SELECT id, source_full_path, target_full_path, direction, enabled FROM repo_mappings ORDER BY id DESC LIMIT 50}, { Slice => {} });
    $c->stash(profiles => $profiles, mappings => $mappings);
    $c->render(template => 'index');
  };

  app->start('daemon', '-l', ($ENV{GITMSYNCD_LISTEN} || 'http://127.0.0.1:9097'));
}

1;
