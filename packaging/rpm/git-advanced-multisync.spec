%global _gitmsyncd_dir /opt/gitmsyncd

Name:           git-advanced-multisync
Version:        0.3.0
Release:        1%{?dist}
Summary:        Multi-provider Git repository sync engine with web UI

License:        Apache-2.0
URL:            https://github.com/DEC-LLC/git-advanced-multisync
Source0:        git-advanced-multisync-%{version}.tar.gz

BuildArch:      noarch

Requires:       perl >= 5.26
Requires:       perl-Mojolicious >= 9.0
Requires:       perl-DBI
Requires:       perl-DBD-Pg
Requires:       postgresql-server >= 12
Requires:       git-core

Provides:       gitmsyncd = %{version}

%description
git-advanced-multisync (gitmsyncd) synchronizes Git repositories across
GitHub, GitLab, and Gitea through a web interface. Supports one-way and
bidirectional sync, auto-discovery, scheduled sync, SSH and HTTPS
transport, conflict detection (ff-only, force-push, reject), and
per-profile repo management.

All configuration happens through the browser — no config files, no CLI.

%prep
%setup -q -n git-advanced-multisync-%{version}

%build
# Perl — nothing to compile

%install
rm -rf $RPM_BUILD_ROOT

mkdir -p $RPM_BUILD_ROOT%{_gitmsyncd_dir}/bin
mkdir -p $RPM_BUILD_ROOT%{_gitmsyncd_dir}/lib/Gitmsyncd
mkdir -p $RPM_BUILD_ROOT%{_gitmsyncd_dir}/web/templates
mkdir -p $RPM_BUILD_ROOT%{_gitmsyncd_dir}/web/public
mkdir -p $RPM_BUILD_ROOT%{_gitmsyncd_dir}/db
mkdir -p $RPM_BUILD_ROOT%{_gitmsyncd_dir}/docs
mkdir -p $RPM_BUILD_ROOT%{_unitdir}
mkdir -p $RPM_BUILD_ROOT%{_sysconfdir}/gitmsyncd
mkdir -p $RPM_BUILD_ROOT%{_localstatedir}/lib/gitmsyncd/workdir

# Application files
cp bin/gitmsyncd.pl $RPM_BUILD_ROOT%{_gitmsyncd_dir}/bin/
cp bin/gitmsyncd-worker.pl $RPM_BUILD_ROOT%{_gitmsyncd_dir}/bin/
cp lib/Gitmsyncd/App.pm $RPM_BUILD_ROOT%{_gitmsyncd_dir}/lib/Gitmsyncd/
cp lib/Gitmsyncd/SyncEngine.pm $RPM_BUILD_ROOT%{_gitmsyncd_dir}/lib/Gitmsyncd/
cp lib/Gitmsyncd/ResourceGovernor.pm $RPM_BUILD_ROOT%{_gitmsyncd_dir}/lib/Gitmsyncd/
cp -a web/templates/*.html.ep $RPM_BUILD_ROOT%{_gitmsyncd_dir}/web/templates/
cp -a web/public/* $RPM_BUILD_ROOT%{_gitmsyncd_dir}/web/public/ 2>/dev/null || true
cp db/schema.sql $RPM_BUILD_ROOT%{_gitmsyncd_dir}/db/
cp -a docs/* $RPM_BUILD_ROOT%{_gitmsyncd_dir}/docs/ 2>/dev/null || true
cp cpanfile $RPM_BUILD_ROOT%{_gitmsyncd_dir}/

# Systemd service
cat > $RPM_BUILD_ROOT%{_unitdir}/gitmsyncd.service << 'SVCEOF'
[Unit]
Description=git-advanced-multisync daemon
Wants=network-online.target postgresql.service
After=network-online.target postgresql.service

[Service]
Type=simple
User=gitmsyncd
Group=gitmsyncd
EnvironmentFile=/etc/gitmsyncd/gitmsyncd.env
ExecStart=/usr/bin/perl /opt/gitmsyncd/bin/gitmsyncd.pl
WorkingDirectory=/opt/gitmsyncd
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

# Multi-instance web template service
# Usage: systemctl enable --now gitmsyncd@infra
# Reads: /etc/gitmsyncd/infra.env
cat > $RPM_BUILD_ROOT%{_unitdir}/gitmsyncd@.service << 'INSTEOF'
[Unit]
Description=gitmsyncd instance - %i
Wants=network-online.target postgresql.service
After=network-online.target postgresql.service

[Service]
Type=simple
User=gitmsyncd
Group=gitmsyncd
EnvironmentFile=/etc/gitmsyncd/%i.env
ExecStart=/usr/bin/perl /opt/gitmsyncd/bin/gitmsyncd.pl
WorkingDirectory=/opt/gitmsyncd
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
INSTEOF

# Worker template service
# For single instance: gitmsyncd-worker@default reads gitmsyncd.env
# For multi-instance:  gitmsyncd-worker@infra   reads infra.env
cat > $RPM_BUILD_ROOT%{_unitdir}/gitmsyncd-worker@.service << 'WRKEOF'
[Unit]
Description=gitmsyncd worker - %i
Wants=network-online.target postgresql.service
After=network-online.target postgresql.service

[Service]
Type=simple
User=gitmsyncd
Group=gitmsyncd
EnvironmentFile=/etc/gitmsyncd/%i.env
ExecStart=/usr/bin/perl /opt/gitmsyncd/bin/gitmsyncd-worker.pl --set=%i
WorkingDirectory=/opt/gitmsyncd
Restart=on-failure
RestartSec=10
KillMode=mixed
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target
WRKEOF

# Default env file
cat > $RPM_BUILD_ROOT%{_sysconfdir}/gitmsyncd/gitmsyncd.env << 'ENVEOF'
GITMSYNCD_DSN=dbi:Pg:dbname=gitmsyncd;host=127.0.0.1;port=5432
GITMSYNCD_DB_USER=gitmsyncd
GITMSYNCD_DB_PASS=changeme
GITMSYNCD_LISTEN=http://0.0.0.0:9097
GITMSYNCD_WORKDIR=/var/lib/gitmsyncd/workdir
GITMSYNCD_MAX_FORKS=4
GITMSYNCD_MAX_LOAD=3.2
GITMSYNCD_MIN_MEM_MB=256
GITMSYNCD_MIN_DISK_MB=1024
ENVEOF

chmod 0600 $RPM_BUILD_ROOT%{_sysconfdir}/gitmsyncd/gitmsyncd.env

%pre
getent group gitmsyncd >/dev/null || groupadd -r gitmsyncd
getent passwd gitmsyncd >/dev/null || \
  useradd -r -g gitmsyncd -d /opt/gitmsyncd -s /sbin/nologin \
  -c "git-advanced-multisync service" gitmsyncd
exit 0

%post
echo ""
echo "git-advanced-multisync installed to /opt/gitmsyncd"
echo ""
echo "Quick start (single instance):"
echo "  1. Edit /etc/gitmsyncd/gitmsyncd.env (set DB password)"
echo "  2. Initialize DB: sudo -u postgres createdb gitmsyncd"
echo "     psql -U gitmsyncd -d gitmsyncd -f /opt/gitmsyncd/db/schema.sql"
echo "  3. systemctl enable --now gitmsyncd"
echo "  4. systemctl enable --now gitmsyncd-worker@default"
echo "  5. Open http://localhost:9097"
echo ""
echo "Multi-instance (each instance gets its own DB, port, and env file):"
echo "  1. cp /etc/gitmsyncd/gitmsyncd.env /etc/gitmsyncd/MYNAME.env"
echo "  2. Edit MYNAME.env: unique DSN, unique LISTEN port, unique WORKDIR"
echo "  3. createdb gitmsyncd_MYNAME"
echo "  4. systemctl enable --now gitmsyncd@MYNAME"
echo "  5. systemctl enable --now gitmsyncd-worker@MYNAME"
echo ""
echo "WARNING: Multiple instances on the same host require adequate CPU,"
echo "memory, disk I/O, and network bandwidth. Each instance runs its own"
echo "web server, worker daemon, and fork pool. A host with < 4 cores,"
echo "< 4GB RAM, or slow storage is NOT suitable for multi-instance."
echo "Use containers on separate hosts for production multi-instance."
echo ""

%files
%defattr(-,root,root,-)
%dir %{_gitmsyncd_dir}
%attr(0755,root,root) %{_gitmsyncd_dir}/bin/gitmsyncd.pl
%attr(0755,root,root) %{_gitmsyncd_dir}/bin/gitmsyncd-worker.pl
%{_gitmsyncd_dir}/lib/
%{_gitmsyncd_dir}/web/
%{_gitmsyncd_dir}/db/
%{_gitmsyncd_dir}/docs/
%{_gitmsyncd_dir}/cpanfile
%{_unitdir}/gitmsyncd.service
%{_unitdir}/gitmsyncd@.service
%{_unitdir}/gitmsyncd-worker@.service
%dir %attr(0755,gitmsyncd,gitmsyncd) %{_localstatedir}/lib/gitmsyncd
%dir %attr(0755,gitmsyncd,gitmsyncd) %{_localstatedir}/lib/gitmsyncd/workdir
%dir %{_sysconfdir}/gitmsyncd
%config(noreplace) %attr(0600,gitmsyncd,gitmsyncd) %{_sysconfdir}/gitmsyncd/gitmsyncd.env

%changelog
* Wed Apr  9 2026 Madhav Diwan <madhav@decllc.biz> - 0.3.0-1
- Separate worker daemon (gitmsyncd-worker) — jobs survive UI restarts
- Fork-per-repo parallelism with configurable max_forks
- Resource governor — CPU, memory, disk checks before forking
- Worker sets for profile-to-worker assignment
- Worker heartbeat and health monitoring on /status page
- SyncEngine extracted to shared module
- Branch-level sync filtering (per-mapping branch globs)
- Configurable workdir via GITMSYNCD_WORKDIR env var
- systemd template unit for workers (gitmsyncd-worker@SETNAME)

* Tue Apr  8 2026 Madhav Diwan <madhav@decllc.biz> - 0.2.0-1
- Scheduler with per-profile intervals and stagger
- SSH transport support with per-provider keys
- Profile-based repo management with auto-discover
- Queue worker for async job processing
- Loop detection (same-provider/same-org blocking)
- Bootstrap 5 web UI with 5 pages
- Three-provider support: GitHub, GitLab, Gitea
