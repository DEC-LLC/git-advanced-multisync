package Gitmsyncd::SyslogExporter;
use strict;
use warnings;
use IO::Socket::INET;
use POSIX qw(strftime);
use Sys::Hostname;
use Exporter 'import';
our @EXPORT_OK = qw(syslog_send syslog_from_db);

# Syslog facility codes
my %FACILITIES = (
    local0 => 16, local1 => 17, local2 => 18, local3 => 19,
    local4 => 20, local5 => 21, local6 => 22, local7 => 23,
    user => 1, daemon => 3, auth => 4, syslog => 5,
);

# Syslog severity codes
my %SEVERITIES = (
    emergency => 0, alert => 1, critical => 2, error => 3,
    warning => 4, notice => 5, info => 6, debug => 7,
);

# Cached socket + config (reused across calls within a process)
my $_socket;
my $_config;

# Load syslog config from DB, cache it
sub syslog_from_db {
    my ($dbh) = @_;
    return unless $dbh;
    my $rows = $dbh->selectall_arrayref(
        q{SELECT key, value FROM instance_settings WHERE key LIKE 'syslog_%'},
        { Slice => {} });
    my %cfg;
    for my $r (@$rows) { $cfg{$r->{key}} = $r->{value}; }
    $_config = \%cfg;
    $_socket = undef;  # reset socket on config reload
    return \%cfg;
}

# Syslog log levels — controls what gets forwarded
#   quiet:    only critical security events (failed login, unbind, admin block)
#   standard: governance + security (above + authorize, revoke, bind)
#   verbose:  above + job completion summaries (one line per job, NOT per file)
my %LEVEL_GATES = (
    quiet    => { emergency => 1, alert => 1, critical => 1 },
    standard => { emergency => 1, alert => 1, critical => 1, error => 1, warning => 1, notice => 1 },
    verbose  => { emergency => 1, alert => 1, critical => 1, error => 1, warning => 1, notice => 1, info => 1 },
);

# Send a syslog message
# syslog_send(severity => 'info', message => 'sync completed', config => \%cfg)
# config is optional — uses cached config from syslog_from_db if not passed
sub syslog_send {
    my (%args) = @_;
    my $cfg = $args{config} || $_config;
    return unless $cfg;
    return unless $cfg->{syslog_enabled} && $cfg->{syslog_enabled} eq 'true';
    return unless $cfg->{syslog_host} && $cfg->{syslog_host} =~ /\S/;

    # Check log level gate — drop messages below configured threshold
    my $level = $cfg->{syslog_level} || 'standard';
    my $gate = $LEVEL_GATES{$level} || $LEVEL_GATES{standard};
    my $sev = $args{severity} || 'info';
    return unless $gate->{$sev};

    my $host     = $cfg->{syslog_host};
    my $port     = $cfg->{syslog_port} || 514;
    my $protocol = $cfg->{syslog_protocol} || 'udp';
    my $facility = $FACILITIES{ $cfg->{syslog_facility} || 'local0' } || 16;
    my $tag      = $cfg->{syslog_tag} || 'gitmsyncd';

    my $severity = $SEVERITIES{ $args{severity} || 'info' } || 6;
    my $priority = ($facility * 8) + $severity;
    my $timestamp = strftime('%b %d %H:%M:%S', localtime);
    my $hostname = hostname();
    my $message = $args{message} || '';

    # RFC 3164 format: <priority>timestamp hostname tag: message
    my $packet = "<$priority>$timestamp $hostname $tag: $message";

    eval {
        if ($protocol eq 'tcp') {
            # TCP: reconnect if socket is gone
            unless ($_socket && $_socket->connected) {
                $_socket = IO::Socket::INET->new(
                    PeerAddr => $host, PeerPort => $port,
                    Proto => 'tcp', Timeout => 5,
                ) or return;
            }
            $_socket->send($packet . "\n");
        } else {
            # UDP: stateless, create per-send (cheap)
            my $sock = IO::Socket::INET->new(
                PeerAddr => $host, PeerPort => $port, Proto => 'udp',
            ) or return;
            $sock->send($packet);
            $sock->close;
        }
    };
    # Silently fail — syslog export should never break sync operations
}

1;
