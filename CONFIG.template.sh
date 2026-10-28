# Settings for this server. After changing anything in the "Backup" section
# (or DOCKER_BINDS_DIR), run "sudo ./configure-borgmatic.sh" to regenerate
# /etc/borgmatic/config.yaml.

# General
DOCKER_BINDS_DIR=""   # root of the containers' bind mounts, e.g. /srv/docker
DOCKER_COMPOSE_DIR="" # holds one <service>/compose.yaml per service
TS_DOMAIN=""
WEB_SERVICES=""       # space-separated; checked by webservice-health-ping.sh,
                      # and selects which exports/<service>.sh run before a backup
CONTAINER_STOP_TIMEOUT="" # optional; seconds containers get to shut down, defaults to 120
LOGS_DIR=""
STATE_DIR=""          # optional; defaults to /var/lib/homeserver-ops

# Backup (borgmatic, via configure-borgmatic.sh)
BORG_REPO_LOCAL=""    # local repository, e.g. /mnt/backup/homeserver
BORG_REPO_OFFSITE=""  # offsite repository, e.g. ssh://user@host/./backups/homeserver
HCHK_SERVER_BACKUP="" # Healthchecks URL for the backup
BORG_PASS_FILE=""     # optional; passphrase file, defaults to .borg-pass in this repository
EXTRA_BACKUP_DIRS=""  # optional; space-separated directories to back up as well
EXTRA_EXCLUDES=""     # optional; space-separated paths or globs to exclude, e.g. network mounts

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
