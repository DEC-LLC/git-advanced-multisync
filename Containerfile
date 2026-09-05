# gitmsyncd — multi-provider Git sync engine (systemd-in-container edition)
#
# FROM DEC-LLC canonical Rocky 10.2 systemd base (task #761 foundation).
# Inherits: /sbin/init as entrypoint, DEC-LLC root CA in trust store,
# decllc-shared/third-party/epel10-curated repo files (disabled at base
# build time; re-enabled per-install as needed).
#
# Downstream Quadlet unit on server3/server4 should pair this with:
#   Network=none  +  container-ovs-attach@gitmsync.service  (host-side helper
#   injects a veth from ovsbr into the container's netns as eth0)
#   PodmanArgs=--systemd=always --cgroupns=host --cap-add=NET_ADMIN --cap-add=NET_RAW
#   HostName=multisync-<host>.decllc.biz
#
# Build:
#   podman build -t gitmsyncd:2026-09-03 .
#
# Push target: registry.gitlab1.decllc.biz/github-mirror/git-advanced-multisync/gitmsyncd:2026-09-03

FROM registry.gitlab1.decllc.biz/infra-containers/container-bases/decllc-rocky10-base:2026-09-02

LABEL org.opencontainers.image.title="gitmsyncd"
LABEL org.opencontainers.image.description="git-advanced-multisync — multi-provider Git sync engine (systemd-in-container, OVS-attach network pattern)"
LABEL org.opencontainers.image.vendor="Diwan Enterprise Consulting LLC"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.source="https://github.com/DEC-LLC/git-advanced-multisync"
LABEL org.opencontainers.image.authors="madhav@decllc.biz"
LABEL org.opencontainers.image.version="2026-09-03"
LABEL biz.decllc.role="git-orchestration"
LABEL biz.decllc.pattern="systemd+ovs-attach"

# --- Install perl + Mojolicious + PG driver + git + procps ---
# decllc-* + epel10-curated are disabled at base build time (repo path 404,
# see RSS 2026-09-03). enable JUST epel-release from Rocky Extras + install
# from real EPEL upstream (matches the pre-productionize Containerfile).
RUN dnf install -y --nodocs --setopt=install_weak_deps=False \
        --disablerepo='decllc-*' --disablerepo='epel10-curated' \
        epel-release && \
    dnf install -y --nodocs --setopt=install_weak_deps=False \
        --disablerepo='decllc-*' --disablerepo='epel10-curated' \
        perl perl-Mojolicious perl-DBI perl-DBD-Pg \
        perl-Digest-SHA perl-POSIX perl-Getopt-Long \
        perl-File-Path perl-Sys-Hostname \
        git-core && \
    dnf clean all && \
    rm -rf /var/cache/dnf /var/log/dnf.* /tmp/* /var/tmp/*

# --- Application layout ---
RUN mkdir -p /opt/gitmsyncd/{bin,lib/Gitmsyncd,web/templates,web/public,db} \
    && mkdir -p /var/lib/gitmsyncd/workdir /etc/gitmsyncd \
    && useradd -r -d /opt/gitmsyncd -s /sbin/nologin gitmsyncd

COPY cpanfile /opt/gitmsyncd/
COPY bin/gitmsyncd.pl bin/gitmsyncd-worker.pl /opt/gitmsyncd/bin/
COPY lib/Gitmsyncd/App.pm lib/Gitmsyncd/SyncEngine.pm lib/Gitmsyncd/ResourceGovernor.pm lib/Gitmsyncd/SyslogExporter.pm /opt/gitmsyncd/lib/Gitmsyncd/
COPY web/templates/*.html.ep /opt/gitmsyncd/web/templates/
COPY db/schema.sql /opt/gitmsyncd/db/

RUN chmod +x /opt/gitmsyncd/bin/*.pl \
    && chown -R gitmsyncd:gitmsyncd /var/lib/gitmsyncd /opt/gitmsyncd /etc/gitmsyncd

# --- Systemd units (managed by inherited /sbin/init) ---
COPY packaging/container/systemd/gitmsyncd-web.service /etc/systemd/system/
COPY packaging/container/systemd/gitmsyncd-worker.service /etc/systemd/system/
RUN systemctl enable gitmsyncd-web.service gitmsyncd-worker.service

# --- Default env (overridable by Quadlet Environment= or /etc/gitmsyncd/env) ---
ENV GITMSYNCD_DSN=dbi:Pg:dbname=gitmsyncd;host=127.0.0.1;port=5432
ENV GITMSYNCD_DB_USER=gitmsyncd
ENV GITMSYNCD_DB_PASS=changeme
ENV GITMSYNCD_LISTEN=http://0.0.0.0:9097
ENV GITMSYNCD_WORKDIR=/var/lib/gitmsyncd/workdir
ENV GITMSYNCD_MAX_FORKS=4
ENV GITMSYNCD_MAX_LOAD=3.2
ENV GITMSYNCD_MIN_MEM_MB=256
ENV GITMSYNCD_MIN_DISK_MB=1024
ENV GITMSYNCD_WORKER_SET=default

EXPOSE 9097

# ENTRYPOINT /sbin/init inherited from base — DO NOT override.
