# Quadlet deploy — gitmsyncd on server3/server4 (OVS-attach pattern)

Two containers, OVS-attached (public IPs, DNS-reachable), fronted by the existing `caddy-tls`
sibling for step-ca TLS termination.

## Prereqs (once per host)

1. `/usr/local/sbin/ovs-attach-container.sh` present (already installed on server3).
2. `container-ovs-attach@.service` systemd template present (already installed on server3).
3. Kea reservations OUTSIDE the dynamic pool on ic1 for both container MACs:
   - `gitmsyncd-<host>.decllc.biz`
   - `gitmsyncd-pg-<host>.decllc.biz`
4. DNS A records for both FQDNs pointing at the reserved IPs (nsupdate against the site's master).
5. caddy-tls config on the host has a reverse-proxy stanza for `gitmsyncd-<host>.decllc.biz` →
   `http://gitmsyncd-<host>.decllc.biz:9097` (step-ca cert already provisioned in caddy trust).

## One-time secrets

Populate from `vtb-credentials-vault`:
- `/etc/gitmsyncd/env` — see `env/gitmsyncd.env.example`
- `/etc/gitmsyncd-pg/env` — see `env/gitmsyncd-pg.env.example`

Both files: mode 0640 root:root (root-only readable; systemd reads them before dropping user).
Password in both env files MUST match.

## Deploy

```
scp packaging/container/systemd/gitmsyncd.container    server3:/etc/containers/systemd/
scp packaging/container/systemd/gitmsyncd-pg.container server3:/etc/containers/systemd/
ssh server3 'systemctl daemon-reload && systemctl start gitmsyncd-pg.service gitmsyncd.service && systemctl enable container-ovs-attach@gitmsyncd.service container-ovs-attach@gitmsyncd-pg.service'
```

## Verify

```
systemctl show gitmsyncd.service    --property=ActiveState,SubState
systemctl show gitmsyncd-pg.service --property=ActiveState,SubState
podman ps --filter name=gitmsyncd
curl -k https://gitmsyncd-<host>.decllc.biz/api/health   # via caddy-tls
```

## HA topology reminder

Per `parked_branches.md` note + Madhav clarification 2026-09-04: server3 <-> server4 is
**semi-cold manual failover backup**, NOT active-active. Identical Quadlets deployed on
both hosts. Only ONE side runs systemd-enabled at a time. PG state carried across via
VaultSync itself (PG per multisync instance is backed up + restored).
