# Settings for this server. After changing anything in the "Backup" section
# (or DOCKER_BINDS_DIR), run "sudo ./configure-borgmatic.sh" to regenerate
# /etc/borgmatic/config.yaml.

# General
DOCKER_BINDS_DIR=""   # root of the containers' bind mounts, e.g. /srv/docker
TS_DOMAIN=""
WEB_SERVICES=""       # space-separated; checked by webservice-health-ping.sh
CONTAINER_STOP_TIMEOUT="" # optional; seconds containers get to shut down, defaults to 120
SKIP_PROJECTS=""      # optional; space-separated compose projects that the backup never stops
                      # and auto-container-update.sh never updates, e.g. nc-aio (Nextcloud AIO)
LOGS_DIR=""
STATE_DIR=""          # optional; defaults to /var/lib/homeserver-ops

# Backup (borgmatic, via configure-borgmatic.sh)
BORG_REPO_LOCAL=""    # local repository, e.g. /mnt/backup/homeserver
BORG_REPO_OFFSITE=""  # offsite repository, e.g. ssh://borg-offsite/home/borg/backups/homeserver
HCHK_SERVER_BACKUP="" # Healthchecks URL for the backup
BORG_PASS_FILE=""     # optional; passphrase file, defaults to .borg-pass in this repository
EXTRA_BACKUP_DIRS=""  # optional; space-separated directories to back up as well
EXTRA_EXCLUDES=""     # optional; space-separated paths or globs to exclude, e.g. network mounts
TIMEMACHINE_DIRS=""   # optional; space-separated folders with Time Machine sparse bundles,
                      # backed up to their own offsite repository only (not the local one)
TIMEMACHINE_SERVICE="" # optional; Samba service stopped while they are archived, defaults to smbd (Fedora: smb)
HCHK_TIMEMACHINE_BACKUP="" # Healthchecks URL for the Time Machine backup; required with TIMEMACHINE_DIRS
BORG_REPO_OFFSITE_TMCHN="" # their own offsite repository; required with TIMEMACHINE_DIRS,
                      # e.g. ssh://borg-offsite/home/borg/backups/timemachine

# Healthchecks (use an instance that does not run on this server)
HCHK_SERVER_PING=""
HCHK_WEBSERVICE_PING=""
HCHK_CONTAINER_UPDATE=""
# one per exports/<service>.sh: HCHK_ + service name in upper case without dashes
HCHK_PAPERLESS=""
HCHK_IMMICH=""
HCHK_BESZEL=""
HCHK_HEALTHCHECKS=""
HCHK_MEALIE=""

# API Keys
APIKY_BESZEL=""
APIKY_MEALIE=""
