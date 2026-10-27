# Homeserver Cron Scripts

Backups, container updates and health monitoring for a docker-based homeserver. Runs on Ubuntu, Fedora and Raspberry Pi OS.

Backups are done by [borgmatic](https://torsion.org/borgmatic/). Each run writes one encrypted, deduplicated archive of the whole server, including every docker volume and bind mount, to a local and an offsite borg repository.

## How a backup works

`backup.sh` (daily, as root) runs borgmatic:

1. **Exports.** For each service in `WEB_SERVICES` that has an `exports/<service>.sh`, the export runs while the service is up. It writes database dumps and app-level exports (paperless exporter, mealie and beszel API backups) into the service's data directory. Each export pings its own `HCHK_<SERVICE>`. A failed export is reported there but does not stop the backup.
2. **Stop.** All running containers are stopped (`hooks/containers.sh stop`), compose projects and plain `docker run` containers alike. Nextcloud AIO is left alone, since it backs itself up. Each container gets `CONTAINER_STOP_TIMEOUT` seconds (default 120) to shut down cleanly. If anything fails to stop, the run aborts before archiving.
3. **Snapshot (where supported).** borgmatic snapshots the file systems holding the backed-up directories, so the OS is captured at one point in time. With `SNAPSHOTS=auto`, `backup.sh` picks the method per host:
   - **LVM** (e.g. Ubuntu Server, Fedora Server): snapshots go on the PVs listed in `LVM_SNAPSHOT_PVS` (see below), or anywhere in the volume group. `hooks/mount.sh` handles XFS snapshots.
   - **Btrfs** (e.g. Fedora Workstation): borgmatic always places the snapshots inside the snapshotted subvolume (`.borgmatic-snapshot-*`). Their location is not configurable.
   - **None** (e.g. Raspberry Pi OS on plain ext4): the live file systems are backed up. Container data is still consistent, because the containers are stopped.
4. **Archive.** borg writes the archive, and the containers are started again.
5. **Housekeeping.** borgmatic prunes (7 daily, 4 weekly, 12 monthly), compacts and, when due, checks the repository:
   - repository: every 2 weeks;
   - archives: monthly;
   - full data verification: every 3 months.

   Containers are already back up during this step. Steps 2–5 repeat for the offsite repository.
6. **Monitoring.** borgmatic pings `HCHK_SERVER_BACKUP` on start, success and failure, with the log attached.

Containers are also started again on any error and when `backup.sh` exits, so they never stay down.

**What is backed up:**
- `/etc /home /root /usr/local /opt /var/lib /var/spool/cron /boot /mnt`, plus `DOCKER_BINDS_DIR` and `ADD_SERVER_BACKUP_SOURCES`;
- every real file system mounted below those;
- all docker named volumes. **New volumes and services are covered automatically.**

**What is excluded:**
- docker images, containers and build cache;
- Nextcloud AIO volumes (AIO runs its own borg backup);
- Immich thumbnails and encoded videos;
- caches (directories with `CACHEDIR.TAG`) and directories containing a `.nobackup` file;
- `/var/cache`, `/var/tmp`, the backup target, and `ADD_SERVER_BACKUP_EXCLSNS`.

`backup.sh` writes these as borg patterns to `$STATE_DIR/patterns` on every run.

## Setup

### 1. Dependencies
- **borg ≥ 1.4** (borgmatic needs it for snapshots). Recent Fedora releases and Debian 13–based systems (including Raspberry Pi OS based on Debian 13) ship it. On older releases, such as Ubuntu 24.04 or Raspberry Pi OS based on Debian 12, use the [standalone binary](https://github.com/borgbackup/borg/releases) or `pipx install borgbackup` (needs the build dependencies listed in borg's install docs).
- **borgmatic ≥ 2.0**. Use the distro package if it is recent enough; otherwise `sudo pipx install --global borgmatic` (see the [borgmatic install docs](https://torsion.org/borgmatic/docs/how-to/set-up-backups/)). `backup.sh` refuses older versions of either.
- **Docker CE with compose v2.** podman is not supported.
- `curl`, `jq`, `unzip`, `flock`.
- For snapshots: `lvm2` (LVM) or `btrfs-progs` (Btrfs).
- **Fedora:** Workstation has no cron daemon by default: `sudo dnf install cronie && sudo systemctl enable --now crond`.

### 2. Configuration
```bash
cp CONFIG.template.sh CONFIG.sh   # then fill it in
```
Put a long random passphrase in `.borg-pass` (first line only) and run `chmod 600 .borg-pass`.

### 3. Create the repositories
```bash
sudo ./backup.sh repo-create --encryption repokey
```

### 4. Store the keys off the server (do not skip this)
The repokey lives inside each repository, and the passphrase lives only on this server. If the server dies, you need **both** to read the offsite copy. Store the passphrase and the key export in a password manager or on paper:
```bash
sudo ./backup.sh key export --repository local
sudo ./backup.sh key export --repository offsite
```

### 5. Cron (root's crontab: `sudo crontab -e`)
```bash
# Backup - daily at 3 AM
0 3 * * * /path/to/backup.sh >> /path/to/logs/backup.log 2>&1
# Container updates - weekly on Monday at 5 AM; refuses to run without a backup from the last 26h
0 5 * * 1 /path/to/auto-container-update.sh >> /path/to/logs/auto-container-update.log 2>&1
# Health checks
*/30 * * * * /path/to/server-health-ping.sh >> /path/to/logs/health.log 2>&1
*/30 * * * * /path/to/webservice-health-ping.sh >> /path/to/logs/webservice-health.log 2>&1
```
The backup and the update share one lock (`lib/lock.sh`), so they wait for each other instead of colliding.

Rotate the logs with `logrotate.conf.template` (install instructions inside).

### 6. First run
```bash
sudo ./backup.sh --dry-run --verbosity 1   # shows what would be done
sudo ./backup.sh
```
The output starts with a line like `📸 Snapshots: lvm`, showing which snapshot method was picked for this host. Set `SNAPSHOTS` in `CONFIG.sh` to override it.

With LVM, check that there is room for one `LVM_SNAPSHOT_SIZE` snapshot **per logical volume** that holds a backed-up directory. For example, the root LV plus a separate LV mounted under `/mnt`. A snapshot that fills up during the backup becomes invalid and makes the run fail.

**Where LVM snapshots go.** By default, LVM puts each snapshot anywhere in its origin's volume group. To give snapshots dedicated space (e.g. a spare eMMC or SSD partition), add that partition to the volume group and list it in `LVM_SNAPSHOT_PVS`:
```bash
sudo pvcreate /dev/mmcblk0p1
sudo vgextend <vg> /dev/mmcblk0p1
sudo pvchange --allocatable n /dev/mmcblk0p1   # optional: reserve it for snapshots
```
- LVM can only place a snapshot in its origin's volume group. With several VGs, list one PV per VG; a VG without a listed PV falls back to "anywhere".
- A reserved (non-allocatable) PV is opened only while a snapshot is created and then reserved again, so growing a regular LV never consumes it. PVs that are allocatable anyway are left as they are.
- A listed device that is not a PV makes the backup fail.

## Restore

```bash
sudo ./backup.sh repo-list --repository local          # list archives
sudo ./backup.sh mount --repository local --archive latest --mount-point /mnt/restore
sudo ./backup.sh umount --mount-point /mnt/restore
# Extract one service's data back into place (paths are stored without the leading /)
sudo ./backup.sh extract --repository local --archive latest \
     --path srv/docker/paperless --path var/lib/docker/volumes/paperless_data --destination /
```
Stop the service before extracting its data, then start it again.

For the database dumps and app exports, follow the restore notes in the header of each `exports/<service>.sh`.

**Restore drill.** A few times a year, restore one service onto a scratch machine or into a temporary directory and start it. A backup you have never restored from is only a hope.

### Archives from before the borgmatic migration
The old per-service repositories (`$BACKUP_LOC/<service>/borg`) are untouched and can still be read with plain borg. Delete them once the new repositories have enough history:
```bash
sudo BORG_PASSCOMMAND="head -n 1 .borg-pass-<service>" borg list "$BACKUP_LOC/<service>/borg"
```

## Scripts

| Script | Purpose |
| --- | --- |
| `backup.sh` | Entry point for backups and for any other borgmatic command (`backup.sh <borgmatic args>`) |
| `borgmatic/config.yaml` | Repositories, retention, checks, snapshots, hooks |
| `hooks/` | borgmatic hooks: package list, exports, container stop/start, `lvcreate` and `mount` wrappers for LVM snapshots |
| `exports/<service>.sh` | Database dumps and app exports, one per service |
| `auto-container-update.sh` | `pull` + `up -d` for each running compose project, then `docker image prune` |
| `server-health-ping.sh`, `webservice-health-ping.sh` | Healthchecks pings for the server and the web services |
| `lib/docker.sh`, `lib/lock.sh`, `ping.sh` | Shared functions |

## Notes
- **Pin major versions** in your compose files (e.g. `postgres:16`). `auto-container-update.sh` then applies only minor updates, and you do major upgrades by hand after reading the release notes.
- **Use a Healthchecks instance that does not run on this server** for the `HCHK_*` URLs, e.g. hc-ping.com. A self-hosted one goes down with the server it is supposed to watch.
- To add an export for a new service, add `exports/<service>.sh` (executable), list the service in `WEB_SERVICES` and optionally set `HCHK_<SERVICE>`.
