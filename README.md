# Homeserver Ops

Backups, container updates and health monitoring for a docker-based homeserver. Runs on Ubuntu, Fedora and Raspberry Pi OS.

Backups are done by [borgmatic](https://torsion.org/borgmatic/), called directly from cron with its standard config file `/etc/borgmatic/config.yaml`. That file is generated from `borgmatic/config.template.yaml` and your `CONFIG.sh` by `configure-borgmatic.sh`, so all settings live in `CONFIG.sh`. Each run writes one encrypted, deduplicated archive of the whole server, including every docker volume and bind mount, to a local and an offsite borg repository.

## How a backup works

Cron runs `flock … borgmatic` daily as root. `flock` takes the lock shared with the update script, then borgmatic does the rest:

1. **Exports.** For each service in `WEB_SERVICES` that has an `exports/<service>.sh`, the export runs while the service is up. It writes database dumps and app-level exports (paperless exporter, mealie and beszel API backups) into the service's data directory. Each export pings its own `HCHK_<SERVICE>`. A failed export is reported there but does not stop the backup.
2. **Stop.** All running containers are stopped (`hooks/containers.sh stop`), compose projects and plain `docker run` containers alike. Nextcloud AIO is left alone, since it backs itself up. Each container gets `CONTAINER_STOP_TIMEOUT` seconds (default 120) to shut down cleanly. If anything fails to stop, the run aborts before archiving.
3. **Archive.** borg writes the archive, and the containers are started again.
4. **Housekeeping.** borgmatic prunes (7 daily, 4 weekly, 12 monthly), compacts and, when due, checks the repository:
   - repository: every 2 weeks;
   - archives: monthly;
   - full data verification: every 3 months.

   Containers are already back up during this step. Steps 2–4 repeat for the offsite repository.
5. **Success marker.** After a fully successful run, `hooks/backup-ok.sh` touches `$STATE_DIR/last-backup-ok`, which `auto-container-update.sh` requires.
6. **Monitoring.** borgmatic pings `HCHK_SERVER_BACKUP` on start, success and failure, with the log attached.

Containers are also started again if any step fails. If borgmatic itself is killed mid-run, the next backup starts them again, or run `sudo /opt/homeserver-ops/hooks/containers.sh start` by hand.

There are no file system snapshots. Container data is consistent because the containers are stopped. The rest is mostly configuration that rarely changes. If borg reports "file changed while we backed it up" for a busy file, such as a log, add it to `EXTRA_EXCLUDES`.

**What is backed up:**
- `/etc /home /root /usr/local /opt /var/lib /var/spool/cron /boot /mnt`, `DOCKER_BINDS_DIR` and `EXTRA_BACKUP_DIRS`;
- every file system mounted below those (e.g. `/boot/efi`, `/boot/firmware`, a disk under `/mnt`);
- all docker named volumes, under `/var/lib/docker/volumes`. **New volumes and services are covered automatically.**

**What is excluded:**
- docker images, containers and build cache;
- Nextcloud AIO volumes (AIO runs its own borg backup);
- Immich thumbnails and encoded videos;
- caches (directories with `CACHEDIR.TAG`) and directories containing a `.nobackup` file;
- `/var/cache`, `/var/tmp` and `EXTRA_EXCLUDES`;
- the local backup disk: its whole mount point if the repository is on a separate disk (so old repositories or other files there are not backed up), otherwise just the repository folder. `configure-borgmatic.sh` prints which one it chose.

## Setup

### 1. Dependencies
- **borg ≥ 1.4.** Recent Fedora releases and Debian 13–based systems (including Raspberry Pi OS based on Debian 13) ship it. On older releases, such as Ubuntu 24.04 or Raspberry Pi OS based on Debian 12, use the [standalone binary](https://github.com/borgbackup/borg/releases) or `pipx install borgbackup` (needs the build dependencies listed in borg's install docs).
- **borgmatic ≥ 2.0.** Use the distro package if it is recent enough; otherwise `sudo pipx install --global borgmatic` (see the [borgmatic install docs](https://torsion.org/borgmatic/docs/how-to/set-up-backups/)).
- **Docker CE with compose v2.** podman is not supported.
- `curl`, `jq`, `unzip`, `flock`.
- `envsubst`, used by `configure-borgmatic.sh`: package `gettext-base` on Debian, Ubuntu and Raspberry Pi OS (usually preinstalled), `gettext-envsubst` or `gettext` on Fedora.
- **Fedora:** Workstation has no cron daemon by default: `sudo dnf install cronie && sudo systemctl enable --now crond`.

### 2. Clone and configure the scripts
```bash
sudo git clone https://github.com/mxreyer/homeserver-ops.git /opt/homeserver-ops
cd /opt/homeserver-ops
sudo cp CONFIG.template.sh CONFIG.sh   # then fill it in, including the "Backup" section
```
Put a long random passphrase in `.borg-pass` (first line only) and run `sudo chmod 600 .borg-pass`.

### 3. Generate the borgmatic config
```bash
sudo ./configure-borgmatic.sh
```
It fills `borgmatic/config.template.yaml` with your `CONFIG.sh` values, validates the result and installs it as `/etc/borgmatic/config.yaml`. If that file already exists, it shows the changes first. **Rerun it whenever you change `CONFIG.sh` or pull updates of this repository.** Don't edit `/etc/borgmatic/config.yaml` by hand: the next run would overwrite it.

### 4. Create the repositories
```bash
sudo borgmatic repo-create --encryption repokey
```

### 5. Store the keys off the server (do not skip this)
The repokey lives inside each repository, and the passphrase lives only on this server. If the server dies, you need **both** to read the offsite copy. Store the passphrase and the key export in a password manager or on paper:
```bash
sudo borgmatic key export --repository local
sudo borgmatic key export --repository offsite
```

### 6. Cron (root's crontab: `sudo crontab -e`)
```bash
# Backup - daily at 3 AM; the lock keeps it and the update from overlapping
0 3 * * * flock -w 14400 /run/lock/homeserver-ops.lock borgmatic --verbosity 1 >> /path/to/logs/backup.log 2>&1
# Container updates - weekly on Monday at 5 AM; refuses to run without a backup from the last 26h
0 5 * * 1 /opt/homeserver-ops/auto-container-update.sh >> /path/to/logs/auto-container-update.log 2>&1
# Health checks
*/30 * * * * /opt/homeserver-ops/server-health-ping.sh >> /path/to/logs/health.log 2>&1
*/30 * * * * /opt/homeserver-ops/webservice-health-ping.sh >> /path/to/logs/webservice-health.log 2>&1
```
Cron's `PATH` may not include `/usr/local/bin`, where `pipx install --global` puts borgmatic. If so, use the full path, e.g. `/usr/local/bin/borgmatic`.

Rotate the logs with `logrotate.conf.template` (install instructions inside).

### 7. First run
```bash
sudo borgmatic --dry-run --verbosity 1   # shows what would be done
sudo borgmatic --verbosity 1
```

## Restore

```bash
sudo borgmatic repo-list --repository local          # list archives
sudo borgmatic mount --repository local --archive latest --mount-point /mnt/restore
sudo borgmatic umount --mount-point /mnt/restore
# Extract one service's data back into place (paths are stored without the leading /)
sudo borgmatic extract --repository local --archive latest \
     --path srv/docker/paperless --path var/lib/docker/volumes/paperless_data --destination /
```
Stop the service before extracting its data, then start it again.

For the database dumps and app exports, follow the restore notes in the header of each `exports/<service>.sh`.

**Restore drill.** A few times a year, restore one service onto a scratch machine or into a temporary directory and start it. A backup you have never restored from is only a hope.

### Archives from before the borgmatic migration
The old per-service repositories (`<backup disk>/<service>/borg`) are untouched and can still be read with plain borg. Delete them once the new repositories have enough history:
```bash
sudo BORG_PASSCOMMAND="head -n 1 .borg-pass-<service>" borg list "<backup disk>/<service>/borg"
```

## Files

| File | Purpose |
| --- | --- |
| `configure-borgmatic.sh` | Generates and installs `/etc/borgmatic/config.yaml` from the template and `CONFIG.sh` |
| `borgmatic/config.template.yaml` | Template for the borgmatic config: what to back up, excludes, retention, checks, hooks |
| `hooks/` | Commands borgmatic runs: package list, exports, container stop/start, success marker |
| `exports/<service>.sh` | Database dumps and app exports, one per service |
| `auto-container-update.sh` | `pull` + `up -d` for each running compose project, then `docker image prune` |
| `server-health-ping.sh`, `webservice-health-ping.sh` | Healthchecks pings for the server and the web services |
| `lib/docker.sh`, `lib/lock.sh`, `lib/ping.sh` | Shared functions |
| `CONFIG.template.sh` | Template for `CONFIG.sh`, all settings of this server |

## Notes
- **Pin major versions** in your compose files (e.g. `postgres:16`). `auto-container-update.sh` then applies only minor updates, and you do major upgrades by hand after reading the release notes.
- **Use a Healthchecks instance that does not run on this server** for the `HCHK_*` URLs, e.g. hc-ping.com. A self-hosted one goes down with the server it is supposed to watch.
- To add an export for a new service, add `exports/<service>.sh` (executable), list the service in `WEB_SERVICES` and optionally set `HCHK_<SERVICE>`.
