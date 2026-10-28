# Homeserver Ops

Backups, container updates and health monitoring for a docker-based homeserver. Runs on Ubuntu, Fedora and Raspberry Pi OS.

Backups are done by [borgmatic](https://torsion.org/borgmatic/), called directly from cron with its standard config file `/etc/borgmatic/config.yaml`. That file is generated from `borgmatic/config.template.yaml` and your `CONFIG.sh` by `configure-borgmatic.sh`, so all settings live in `CONFIG.sh`. Each run writes one encrypted, deduplicated archive of the whole server, including every docker volume and bind mount, to a local and an offsite borg repository.

## How a backup works

Cron runs `flock … borgmatic` daily as root. `flock` takes the lock shared with the update script, then borgmatic does the rest:

1. **Exports.** For each running compose project that has an `exports/<project>.sh`, the export runs while the service is up. It writes database dumps and app-level exports (paperless exporter, mealie and beszel API backups) into the service's data directory. Each export pings its own `HCHK_<PROJECT>`; an export whose project isn't running is skipped without a ping, so its healthcheck flags it. A failed export is reported there but does not stop the backup.
2. **Stop.** All running containers are stopped (`hooks/containers.sh stop`), compose projects and plain `docker run` containers alike. Nextcloud AIO is left alone, since it backs itself up. Each container gets `CONTAINER_STOP_TIMEOUT` seconds (default 120) to shut down cleanly. If anything fails to stop, the run aborts before archiving.
3. **Archive.** borg writes the archive, and the containers are started again.
4. **Housekeeping.** borgmatic prunes (7 daily, 4 weekly, 12 monthly), compacts and, when due, runs the repository checks described under [Repository checks](#repository-checks). Containers are already back up during this step. Steps 2–4 repeat for the offsite repository.
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
- `/var/cache`, `/var/tmp`, the local borg repository itself, and `EXTRA_EXCLUDES`.

## Setup

### 1. Dependencies
- **borg 1.4** (≥ 1.4, < 2) from the distribution: `sudo apt install borgbackup` (Fedora: `sudo dnf install borgbackup`). borg 2 uses a new, incompatible repository format.
- **borgmatic ≥ 2.0**, installed with [uv](https://docs.astral.sh/uv/) as recommended by the [borgmatic install docs](https://torsion.org/borgmatic/docs/how-to/set-up-backups/) (see below).
- **Docker CE with compose v2.** podman is not supported.
- `curl`, `jq`, `unzip`, `flock`.
- `envsubst`, used by `configure-borgmatic.sh`: package `gettext-base` on Debian, Ubuntu and Raspberry Pi OS (usually preinstalled), `gettext-envsubst` or `gettext` on Fedora.
- **Fedora:** Workstation has no cron daemon by default: `sudo dnf install cronie && sudo systemctl enable --now crond`.

uv itself is not in apt on Ubuntu 24.04 (check `apt-cache policy uv` on other releases). Install it with Astral's installer into `/usr/local/bin`: `curl -LsSf https://astral.sh/uv/install.sh | sudo env UV_INSTALL_DIR=/usr/local/bin sh`. On Fedora: `sudo dnf install uv`.

Install borgmatic system-wide with uv, so that root and cron find it in `/usr/local/bin`:
```bash
sudo env UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool install borgmatic
```
Update it later with `sudo env UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool upgrade borgmatic`.

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
Then restrict the server's access to the offsite repository to append-only, as described under [Protect the offsite copy](#protect-the-offsite-copy-append-only). Do this after `repo-create`, which needs normal access.

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
# Full data verification of the local repository - 1 Jan and 1 Jul at 5 AM, after the backup
0 5 1 1,7 * flock -w 14400 /run/lock/homeserver-ops.lock borgmatic check --only data --force --repository local --verbosity 1 >> /path/to/logs/backup-verify.log 2>&1
# Container updates - weekly on Monday at 5 AM; refuses to run without a backup from the last 26h
0 5 * * 1 /opt/homeserver-ops/auto-container-update.sh >> /path/to/logs/auto-container-update.log 2>&1
# Health checks
*/30 * * * * /opt/homeserver-ops/server-health-ping.sh >> /path/to/logs/health.log 2>&1
*/30 * * * * /opt/homeserver-ops/webservice-health-ping.sh >> /path/to/logs/webservice-health.log 2>&1
```
Cron's `PATH` may not include `/usr/local/bin`, where the uv install above puts borgmatic. If so, use the full path, e.g. `/usr/local/bin/borgmatic`.

Rotate the logs with `logrotate.conf.template` (install instructions inside).

### Repository checks
borg can check a repository at three levels. The schedule is sized for repositories of several TB, and all results go to `HCHK_SERVER_BACKUP`:

| Check | What it verifies | When |
| --- | --- | --- |
| repository | The checksum of every stored block (disk corruption). For the offsite repository, it runs on the remote machine without downloading anything. | Weekly, both repositories, at most 3 hours per run; the next run continues where it stopped, so a few TB are covered every few weeks. |
| archives | Every archive's metadata: readable and complete, no missing blocks. | Monthly, both repositories. |
| data | Downloads, decrypts and cryptographically verifies every block. Also detects tampering, or corruption that happens to leave the checksum intact. | Twice a year, **local repository only**, from its own cron line (it reads the whole repository). The offsite repository is not data-checked: that would download several TB, and its weekly repository check already covers disk corruption there. |

None of these replaces a restore drill (below).

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

## Protect the offsite copy (append-only)
The server holds the borg passphrase and an SSH key for the offsite machine. An attacker who takes over the server, e.g. ransomware, could use them to delete the offsite archives too. To prevent that, the offsite machine lets the server's key only *add* to the repository.

**Setup, on the offsite machine:** in `~/.ssh/authorized_keys` of the user that owns the repository, prefix the server's key (root's, since borgmatic runs as root) with a forced command:
```
command="borg serve --append-only --restrict-to-repository /path/to/backups/homeserver",restrict ssh-ed25519 AAAA… root@homeserver
```
The key can then only run borg in append-only mode on that one repository, and the server cannot lift this restriction. Test it once from the server: `sudo borgmatic repo-list --repository offsite` should still work.

**What changes:** the nightly backup and the checks work as before. But for the offsite repository:
- `prune` and any `delete` only *hide* archives. They disappear from listings, but their data stays in the repository and can be restored by rolling back. borg records every change with a timestamp in the repository's `transactions` file.
- `compact` frees nothing, so the offsite repository keeps growing until you compact it yourself (below). Plan its disk space accordingly.

**Compacting, every few months, on the offsite machine:**
1. On the server, check the offsite archive list looks as expected: `sudo borgmatic repo-list --repository offsite` should show the recent daily, weekly and monthly archives.
2. If archives are missing that the retention rules (7 daily, 4 weekly, 12 monthly) would have kept, **don't compact**: someone may have deleted them. Roll the repository back instead, following "Append-only mode" in borg's [usage notes](https://borgbackup.readthedocs.io/en/stable/usage/notes.html).
3. Otherwise, as the repository owner on the offsite machine (not through the restricted key): `borg compact /path/to/backups/homeserver`. This makes the pruned deletions final and frees their space. It needs no passphrase.

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
- **The offsite repository only grows** while it is append-only. Compact it every few months as described in [Protect the offsite copy](#protect-the-offsite-copy-append-only).
- **Use a Healthchecks instance that does not run on this server** for the `HCHK_*` URLs, e.g. hc-ping.com. A self-hosted one goes down with the server it is supposed to watch.
- To add an export for a new service, add an executable `exports/<project>.sh` named after its compose project, and optionally set `HCHK_<PROJECT>`. It runs automatically whenever that project is running.
