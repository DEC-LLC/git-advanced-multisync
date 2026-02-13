# GitLab1 Deployment and Operations Record (2026-02-13)

## Scope
This document records the architecture, provisioning, storage layout, and post-install administration steps completed for `gitlab1.decllc.biz`.

## Infrastructure Architecture

- Hypervisor: `pve2.decllc.biz` (Proxmox VE 8.4.16)
- VM name: `gitlab1.decllc.biz`
- VMID: `106`
- VM storage backend: `Local-ZFS-Tank` (zfspool)
- OS ISO source: `local:iso/debian-13.2.0-amd64-DVD-1.iso`

### VM Hardware Layout
- Machine type: `q35`
- Firmware: `OVMF` (UEFI)
- CPU: `host`, 8 cores, 1 socket
- RAM: `16384 MB` (balloon min `2048 MB`)
- NIC: `virtio` on `vmbr0`
- Disks on `Local-ZFS-Tank`:
  - `efidisk0` (UEFI vars)
  - `scsi0` (OS): `120G`
  - `scsi1` (data): `1T`

## Guest OS and Software

- Distribution: Debian GNU/Linux 13 (trixie)
- GitLab install method: official apt repo (`packages.gitlab.com/gitlab/gitlab-ce`)
- GitLab version installed: `18.8.4-ce.0` (reports as `18.8.4`)
- External URL: `http://gitlab1.decllc.biz`

## Storage and LVM Design

### OS disk (`/dev/sda`) VG: `gitlab1-vg`
Current logical volumes:
- `root`: `40G` mounted at `/`
- `var`: `30G` mounted at `/var`
- `home`: `40G` mounted at `/home`
- `tmp`: `1.56G` mounted at `/tmp`
- `swap_1`: `5.96G`

### Data disk (`/dev/sdb`) VG: `gitlab-data-vg`
- PV: `/dev/sdb`
- LV: `gitlab_data` (full disk)
- Filesystem: `xfs`
- Mountpoint: `/var/opt/gitlab`
- fstab entry:
  - `/dev/mapper/gitlab--data--vg-gitlab_data /var/opt/gitlab xfs defaults,noatime 0 2`

## Networking and Service Ports

- Apache package was occupying port 80 after base OS install.
- Apache was disabled to avoid conflict with Omnibus GitLab NGINX.
- GitLab NGINX now serves on port 80.

## APT Source Layout

- `/etc/apt/sources.list` reduced to managed placeholder.
- Debian sources moved to `/etc/apt/sources.list.d/debian.sources`.
- GitLab CE source added at `/etc/apt/sources.list.d/gitlab_gitlab-ce.list`.
- CDROM source removed from active apt configuration.

## Accounts and Privileges

### Linux users on gitlab1
- `madhav`, `nikhil`, `paul`
- All in `sudo` group.

### GitLab users
- `madhav`, `nikhil`, `paul`
- All set to `admin=true`.

## Runner/Ollama Related Discovery

- `server3.decllc.biz`:
  - `ollama` container running (mapped `11434`)
  - `open-webui` container running (mapped `8080`)
  - `gitlab-runner` binary not installed
- `studio1.decllc.biz`:
  - `gitlab-runner` binary not installed
  - Podman present with existing containers

## Operational Notes

- Root initial GitLab password exists in `/etc/gitlab/initial_root_password` (host-local secret).
- Additional temporary user credentials generated during setup were written only on `gitlab1` under `/root/` files as needed.
- Reusable admin scripts for this deployment are checked into `scripts/admin/` in this repo.

## Validation Snapshot (post-change)

- `/var`: `30G`
- `/home`: `40G`
- `/var/opt/gitlab`: `~1T` xfs mount on dedicated data VG
- GitLab services active (`gitlab-ctl status` healthy)
- GitLab URL responding via NGINX on port 80

## Mirror Service (GitHub -> GitLab)

Implemented as systemd-managed job (not crontab):
- Service: `github-gitlab-mirror.service`
- Timer: `github-gitlab-mirror.timer` (every 30 minutes)
- Run user: `githubgitlabsync`
- Reverse-sync placeholder user created: `gitlabgithubsync`

Artifacts on gitlab1:
- Script: `/usr/local/bin/github_gitlab_mirror.sh`
- Env file: `/etc/github-gitlab-mirror/github-gitlab-mirror.env`
- Repo list: `/etc/github-gitlab-mirror/github-repos.list`
- Work dir: `/var/lib/githubgitlabsync/mirror-work`

Current status:
- Timer enabled and active.
- Service last run completed successfully.
- Initial mirroring created/pushed repositories into group `github-mirror`.

## Runner Fleet

Installed and registered GitLab Runner 18.8.0 from package repos on:
- `server3.decllc.biz` (Rocky 9): `server3-shell-runner` tags `server3,rocky9,ollama,shell`
- `server4.decllc.biz` (Rocky 9): `server4-shell-runner` tags `server4,rocky9,ollama,shell`
- `studio1.decllc.biz` (Ubuntu 24.04): `studio1-shell-runner` tags `studio1,ubuntu2404,shell`

All three runners verified online in GitLab.

## Script Integrity

SHA256 manifest generated for scripts:
- `scripts/SHA256SUMS.txt`
- `scripts/SHA256SUMS.txt.sha256`
