# Homeserver Ops

Backups, container updates and health monitoring for a docker-based homeserver. Runs on Ubuntu, Fedora and Raspberry Pi OS.

Backups are done by [borgmatic](https://torsion.org/borgmatic/), called directly from cron with its standard config file `/etc/borgmatic/config.yaml`. That file is generated from `borgmatic/config.template.yaml` and your `CONFIG.sh` by `configure-borgmatic.sh`, so all settings live in `CONFIG.sh`. Each run writes one encrypted, deduplicated archive of the whole server, including every docker volume and bind mount, to a local and an offsite borg repository.

## How a backup works

Cron runs `flock … borgmatic` daily as root. `flock` takes the lock shared with the update script, then borgmatic does the rest:

1. **Exports.** For each running compose project that has an `exports/<project>.sh`, the export runs while the service is up. It writes database dumps and app-level exports (paperless exporter, mealie and beszel API backups) into the service's data directory. Each export pings its own `HCHK_<PROJECT>`; an export whose project isn't running is skipped without a ping, so its healthcheck flags it. A failed export is reported there but does not stop the backup.
2. **Stop.** All running containers are stopped (`hooks/containers.sh stop`), compose projects and plain `docker run` containers alike. Nextcloud AIO is left alone, since it backs itself up. Each container gets `CONTAINER_STOP_TIMEOUT` seconds (default 120) to shut down cleanly. If anything fails to stop, the run aborts before archiving.
3. **Archive.** borg writes the archive, and the containers are started again.
4. **Housekeeping.** borgmatic prunes (7 daily, 4 weekly, 12 monthly), compacts and, when due, runs the repository checks described under [Repository checks](#repository-checks). Containers are already back up during this step. Steps 2–4 repeat for the offsite repository. Because the offsite repository is append-only, pruning there only *hides* old archives (their data stays and can be restored by rolling back), and compacting frees nothing until you compact it yourself on the offsite machine (see [Maintenance](#maintenance-every-few-months)).
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
Steps marked **server** run on the homeserver, steps marked **offsite** on the offsite machine: another machine you reach over SSH, e.g. a Raspberry Pi at a friend's or family member's place. If it is outside your network, make it reachable over SSH, e.g. via Tailscale. The server gets a dedicated SSH key that can do nothing but add backups to that one repository.

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

### 2. Clone and configure the scripts (server)
```bash
sudo git clone https://github.com/mxreyer/homeserver-ops.git /opt/homeserver-ops
cd /opt/homeserver-ops
sudo cp CONFIG.template.sh CONFIG.sh   # then fill it in, including the "Backup" section
```
Put a long random passphrase in `.borg-pass` (first line only) and run `sudo chmod 600 .borg-pass`.

### 3. Prepare the offsite machine
1. **Offsite:** install borg (same major version as on the server, `sudo apt install borgbackup`), create a user without a password and its backup folder:
   ```bash
   sudo adduser --disabled-password --gecos "" borg
   sudo -u borg mkdir -p /home/borg/backups
   ```
2. **Server:** create a dedicated key for root (borgmatic runs as root), without a passphrase so cron can use it, and a host alias for it:
   ```bash
   sudo ssh-keygen -t ed25519 -N "" -C "borg@homeserver" -f /root/.ssh/id_ed25519_borg
   sudo tee -a /root/.ssh/config > /dev/null <<'END'
   # HostName: the offsite machine's address
   Host borg-offsite
       HostName offsite.example
       User borg
       IdentityFile /root/.ssh/id_ed25519_borg
       IdentitiesOnly yes
   END
   sudo cat /root/.ssh/id_ed25519_borg.pub   # copy this for the next step
   ```
3. **Offsite:** allow that key to run nothing but borg, on that one repository. Append-only comes in step 5, after the repository has been created:
   ```bash
   sudo install -d -m 700 -o borg -g borg /home/borg/.ssh
   echo 'command="borg serve --restrict-to-repository /home/borg/backups/homeserver",restrict ssh-ed25519 AAAA… borg@homeserver' \
     | sudo tee /home/borg/.ssh/authorized_keys > /dev/null
   sudo chown borg:borg /home/borg/.ssh/authorized_keys && sudo chmod 600 /home/borg/.ssh/authorized_keys
   ```
4. **Server:** connect once to confirm the offsite machine's host key (cron cannot answer that question later): `sudo ssh borg-offsite true`. Answer `yes`. It then prints borg's help text instead of running `true`, because the key may only run borg. That is expected.
5. **Server:** set `BORG_REPO_OFFSITE="ssh://borg-offsite/home/borg/backups/homeserver"` in `CONFIG.sh`. The path must match the one in `authorized_keys` exactly.

### 4. Generate the borgmatic config (server)
```bash
sudo ./configure-borgmatic.sh
```
It fills `borgmatic/config.template.yaml` with your `CONFIG.sh` values, validates the result and installs it as `/etc/borgmatic/config.yaml`. If that file already exists, it shows the changes first. **Rerun it whenever you change `CONFIG.sh` or pull updates of this repository.** Don't edit `/etc/borgmatic/config.yaml` by hand: the next run would overwrite it.

### 5. Create the repositories, then make the offsite one append-only
1. **Server:** `sudo borgmatic repo-create --encryption repokey`
2. **Offsite:** add `--append-only` to the forced command in `/home/borg/.ssh/authorized_keys`. From now on the server can only *add* to that repository. The server holds the borg passphrase and this SSH key, so an attacker who takes over the server (e.g. ransomware) could otherwise use them to delete the offsite archives too. The restriction lives on the offsite machine, so the server cannot lift it:
   ```
   command="borg serve --append-only --restrict-to-repository /home/borg/backups/homeserver",restrict ssh-ed25519 AAAA… borg@homeserver
   ```

### 6. Store the keys off the server (server, do not skip this)
The repokey lives inside each repository, and the passphrase lives only on this server. If the server dies, you need **both** to read the offsite copy. Store the passphrase and the key export in a password manager or on paper:
```bash
sudo borgmatic key export --repository local
sudo borgmatic key export --repository offsite
```

### 7. Harden SSH on the offsite machine (offsite)
```bash
printf 'PasswordAuthentication no\nPermitRootLogin no\n' | sudo tee /etc/ssh/sshd_config.d/01-hardening.conf
sudo sshd -T | grep -E '^(passwordauthentication|permitrootlogin) '   # both must say "no"
sudo systemctl reload ssh   # on Fedora: sshd
```
The file name starts with `01-` on purpose: sshd uses the first value it reads, and many systems ship e.g. `50-cloud-init.conf` with `PasswordAuthentication yes`.

**Administer the offsite machine from another device** (e.g. your laptop) with a key that never sits on the server, and make sure no other key from the server is in any `authorized_keys` there. Otherwise an attacker on the server could bypass the restriction. To protect that admin login against malware on the laptop as well, add a one-time code:

#### Optional: admin logins with a one-time code
With this, your admin login on the offsite machine needs the SSH key **and** a 6-digit code from an authenticator app on your phone (e.g. 2FAS). Malware on your laptop then cannot log in on its own, even with your key. The borg key keeps working without a code, so the nightly backups are not affected. Replace `admin` with your login name.

Keep one SSH session to the offsite machine open the whole time and test from a second terminal, so a mistake cannot lock you out.

1. **Install the module and create your secret** (as your admin user, not with sudo):
   ```bash
   sudo apt install libpam-google-authenticator
   google-authenticator -t -d -f -r 3 -R 30 -w 3
   ```
   Scan the QR code with your authenticator app, or type in the secret key. Save the printed **emergency scratch codes** in your password manager: they are single-use codes for when your phone is not at hand. The flags mean: time-based codes (`-t`), each code usable once (`-d`), at most 3 logins per 30 seconds (`-r 3 -R 30`), tolerate a small clock difference (`-w 3`), and write `~/.google_authenticator` without asking (`-f`).
2. **Require the code only for the admin user,** in `/etc/ssh/sshd_config.d/02-totp.conf`:
   ```
   # Admin logins need the SSH key AND a TOTP code; every other user (e.g. the
   # restricted borg key) keeps key-only logins, so unattended backups still work.
   KbdInteractiveAuthentication yes
   AuthenticationMethods publickey
   Match User admin
       AuthenticationMethods publickey,keyboard-interactive
   ```
   It has to be a drop-in: the main `sshd_config` sets `KbdInteractiveAuthentication no` further down, and sshd uses the first value it reads.
3. **Ask for the code instead of the password:** in `/etc/pam.d/sshd`, replace the line `@include common-auth` with:
   ```
   #@include common-auth
   auth required pam_google_authenticator.so
   ```
   Otherwise SSH would also ask for the Unix password (password logins are already disabled above).
4. **Check and apply:**
   ```bash
   sudo sshd -t                                                                    # no output: valid
   sudo sshd -T -C user=admin,host=x,addr=127.0.0.1 | grep authenticationmethods   # publickey,keyboard-interactive
   sudo sshd -T -C user=borg,host=x,addr=127.0.0.1  | grep authenticationmethods   # publickey
   sudo systemctl reload ssh   # on Fedora: sshd
   ```
5. **Test, with the old session still open:** `ssh admin@<offsite machine>` from your laptop now asks for `Verification code:` after the key. From the server, `sudo borgmatic repo-list --repository offsite` still works without a code.

Codes only work if the offsite machine's clock is right (`timedatectl` shows "System clock synchronized: yes"). A Raspberry Pi has no battery-backed clock: right after a power cut, before it has network, use a scratch code or wait until the time has synced. Enable your authenticator app's backup, so a lost phone does not lock you out.

### 8. Cron (server, root's crontab: `sudo crontab -e`)
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

### 9. First run and tests (server)
```bash
sudo borgmatic --dry-run --verbosity 1   # shows what would be done
sudo borgmatic --verbosity 1
```
Then check that the offsite restriction works:
- `sudo borgmatic repo-list --repository offsite` lists the archives;
- `sudo ssh borg-offsite ls /` prints only borg's help text, no files;
- `sudo borg list ssh://borg-offsite/home/borg/backups/other` fails with "Repository path not allowed" (use any path *other* than your repository's).

## Repository checks
borg can check a repository at three levels. The schedule is sized for repositories of several TB, and all results go to `HCHK_SERVER_BACKUP`:

| Check | What it verifies | When |
| --- | --- | --- |
| repository | The checksum of every stored block (disk corruption). For the offsite repository, it runs on the remote machine without downloading anything. | Weekly, both repositories, at most 3 hours per run; the next run continues where it stopped, so a few TB are covered every few weeks. |
| archives | Every archive's metadata: readable and complete, no missing blocks. | Monthly, both repositories. |
| data | Downloads, decrypts and cryptographically verifies every block. Also detects tampering, or corruption that happens to leave the checksum intact. | Twice a year, **local repository only**, from its own cron line (it reads the whole repository). The offsite repository is not data-checked: that would download several TB, and its weekly repository check already covers disk corruption there. |

None of these replaces a restore drill (see [Maintenance](#maintenance-every-few-months)).

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

Practise this regularly: the restore drill is part of the [Maintenance](#maintenance-every-few-months) routine.

## Maintenance (every few months)
The append-only offsite repository keeps growing until you compact it (step 3); plan its disk space accordingly.

1. **Restore drill.** Restore one service from the latest archive onto a scratch machine or into a temporary directory, and start it (see [Restore](#restore)). Check that its files are intact and readable: ransomware would leave encrypted garbage in the newest archives. A backup you have never restored from is only a hope.
   - **Alternate between the repositories** (`--repository local` / `--repository offsite`). The offsite repository gets no full data check, so restoring from it is its real test.
   - **Once a year, use your recovery material instead of the server's files:** `sudo borg list ssh://borg-offsite/home/borg/backups/homeserver` asks for the passphrase; type it from your password manager, not from `.borg-pass`. Also compare `sudo borgmatic key export --repository local` and `--repository offsite` with the key exports stored there. That proves you could recover after losing the server.
2. **Check the offsite archive list.** On the server: `sudo borgmatic repo-list --repository offsite` should show the recent daily, weekly and monthly archives (retention: 7 daily, 4 weekly, 12 monthly). If archives are missing that the retention rules would have kept, **stop here and don't compact**: someone may have deleted them. Roll the repository back instead, following "Append-only mode" in borg's [usage notes](https://borgbackup.readthedocs.io/en/stable/usage/notes.html).
3. **Compact the offsite repository.** Only if steps 1 and 2 look fine, from your admin login on the offsite machine (not through the server's restricted key):
   ```bash
   sudo -u borg borg compact /home/borg/backups/homeserver
   ```
   This makes the pruned deletions final and frees their space. It needs no passphrase.
4. **Audit the offsite machine's access,** from your admin login there:
   ```bash
   sudo cat /home/borg/.ssh/authorized_keys ~/.ssh/authorized_keys
   sudo ls /root/.ssh/authorized_keys 2>/dev/null   # should not exist
   sudo sshd -T | grep -E '^(passwordauthentication|permitrootlogin) '   # both "no"
   ```
   The borg user must have only the restricted backup line (`command="borg serve --append-only --restrict-to-repository …",restrict …`), your admin user only your laptop's key, and no key from the server may appear anywhere else. If you set up the one-time code, `sudo sshd -T -C user=admin,host=x,addr=127.0.0.1 | grep authenticationmethods` must still show `publickey,keyboard-interactive`.
5. **Update the software.**
   - Server: `sudo apt update && sudo apt upgrade` (includes borg), `sudo env UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool upgrade borgmatic`, and this repository: `cd /opt/homeserver-ops && sudo git pull && sudo ./configure-borgmatic.sh` (shows the config changes).
   - Offsite machine: `sudo apt update && sudo apt upgrade`, or enable `unattended-upgrades` there.
   - Keep borg on the same major version on both machines: borg 2 is not compatible with these repositories.

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
- **Every few months:** restore drill, offsite archive check, compaction, access audit and updates, see [Maintenance](#maintenance-every-few-months).
- **Use a Healthchecks instance that does not run on this server** for the `HCHK_*` URLs, e.g. hc-ping.com. A self-hosted one goes down with the server it is supposed to watch.
- To add an export for a new service, add an executable `exports/<project>.sh` named after its compose project, and optionally set `HCHK_<PROJECT>`. It runs automatically whenever that project is running.
