%global _gitmsyncd_dir /opt/gitmsyncd

Name:           git-advanced-multisync
Version:        0.2.0
Release:        1%{?dist}
Summary:        Multi-provider Git repository sync engine with web UI

License:        MIT and GPLv3
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

mkdir -p $RPM_BUILD_ROOT%{_gitmsyncd_dir}/{bin,lib/Gitmsyncd,web/templates,web/public,db,docs}
mkdir -p $RPM_BUILD_ROOT%{_unitdir}
mkdir -p $RPM_BUILD_ROOT%{_sysconfdir}/gitmsyncd

# Application files
cp bin/gitmsyncd.pl $RPM_BUILD_ROOT%{_gitmsyncd_dir}/bin/
cp lib/Gitmsyncd/App.pm $RPM_BUILD_ROOT%{_gitmsyncd_dir}/lib/Gitmsyncd/
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

# Default env file
cat > $RPM_BUILD_ROOT%{_sysconfdir}/gitmsyncd/gitmsyncd.env << 'ENVEOF'
GITMSYNCD_DSN=dbi:Pg:dbname=gitmsyncd;host=127.0.0.1;port=5432
GITMSYNCD_DB_USER=gitmsyncd
GITMSYNCD_DB_PASS=changeme
GITMSYNCD_LISTEN=http://0.0.0.0:9097
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
echo "Quick start:"
echo "  1. Edit /etc/gitmsyncd/gitmsyncd.env (set DB password)"
echo "  2. Initialize DB: sudo -u postgres createdb gitmsyncd"
echo "     psql -U gitmsyncd -d gitmsyncd -f /opt/gitmsyncd/db/schema.sql"
echo "  3. systemctl enable --now gitmsyncd"
echo "  4. Open http://localhost:9097"
echo ""

%files
%defattr(-,root,root,-)
%dir %{_gitmsyncd_dir}
%attr(0755,root,root) %{_gitmsyncd_dir}/bin/gitmsyncd.pl
%{_gitmsyncd_dir}/lib/
%{_gitmsyncd_dir}/web/
%{_gitmsyncd_dir}/db/
%{_gitmsyncd_dir}/docs/
%{_gitmsyncd_dir}/cpanfile
%{_unitdir}/gitmsyncd.service
%dir %{_sysconfdir}/gitmsyncd
%config(noreplace) %attr(0600,gitmsyncd,gitmsyncd) %{_sysconfdir}/gitmsyncd/gitmsyncd.env

%changelog
* Tue Apr  8 2026 Madhav Diwan <madhav@decllc.biz> - 0.2.0-1
- Scheduler with per-profile intervals and stagger
- SSH transport support with per-provider keys
- Profile-based repo management with auto-discover
- Queue worker for async job processing
- Loop detection (same-provider/same-org blocking)
- Bootstrap 5 web UI with 5 pages
- Three-provider support: GitHub, GitLab, Gitea
