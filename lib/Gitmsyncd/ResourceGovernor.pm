package Gitmsyncd::ResourceGovernor;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(check_resources);

sub check_resources {
    my (%limits) = @_;
    my $max_load    = $limits{max_load}    || 3.2;
    my $min_mem_mb  = $limits{min_mem_mb}  || 256;
    my $min_disk_mb = $limits{min_disk_mb} || 1024;
    my $workdir     = $limits{workdir}     || '/tmp/gitmsyncd-workdir';

    # CPU: 1-minute load average from /proc/loadavg
    if (open my $fh, '<', '/proc/loadavg') {
        my $load = (split /\s+/, <$fh>)[0];
        close $fh;
        if ($load >= $max_load) {
            return (0, "cpu load $load >= $max_load");
        }
    }

    # Memory: MemAvailable from /proc/meminfo
    if (open my $fh, '<', '/proc/meminfo') {
        while (<$fh>) {
            if (/^MemAvailable:\s+(\d+)/) {
                my $avail_mb = $1 / 1024;
                close $fh;
                if ($avail_mb < $min_mem_mb) {
                    return (0, sprintf("memory %dMB < %dMB", $avail_mb, $min_mem_mb));
                }
                last;
            }
        }
        close $fh;
    }

    # Disk: available space on workdir filesystem
    my $df_line = `df -k --output=avail '$workdir' 2>/dev/null | tail -1`;
    if ($df_line && $df_line =~ /(\d+)/) {
        my $avail_mb = $1 / 1024;
        if ($avail_mb < $min_disk_mb) {
            return (0, sprintf("disk %dMB < %dMB", $avail_mb, $min_disk_mb));
        }
    }

    return (1, "ok");
}

1;
