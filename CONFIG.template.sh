# General
DOCKER_BINDS_DIR=""   # root of the containers' bind mounts, e.g. /srv/docker
DOCKER_COMPOSE_DIR="" # holds one <service>/compose.yaml per service
DOCKER_VOL_LOC=""     # docker's named volumes, usually /var/lib/docker/volumes
TS_DOMAIN=""
WEB_SERVICES=""       # space-separated; checked by webservice-health-ping.sh,
                      # and selects which exports/<service>.sh run before a backup
CONTAINER_STOP_TIMEOUT="" # optional; seconds containers get to shut down, defaults to 120
LOGS_DIR=""
STATE_DIR=""          # optional; defaults to /var/lib/homeserver-ops

# Backup (backup.sh / borgmatic)
BACKUP_LOC=""         # local repo parent dir, e.g. /mnt/backup
BACKUP_SSH=""         # offsite repo parent, e.g. ssh://user@host/./backups
BORG_REPO_NAME=""     # optional; repo dir name in both, defaults to "homeserver"
ADD_SERVER_BACKUP_SOURCES="" # space-separated extra directories to back up
ADD_SERVER_BACKUP_EXCLSNS="" # space-separated extra paths/globs to exclude
SNAPSHOTS=""          # optional; "auto" (default), "lvm", "btrfs", "lvm btrfs" or "none"
LVM_SNAPSHOT_SIZE=""  # optional; per snapshot, e.g. 10G or 10%ORIGIN; defaults to 10G
LVM_SNAPSHOT_PVS=""   # optional; space-separated PVs to place LVM snapshots on, e.g.
                      # "/dev/mmcblk0p1". Each snapshot uses those in its origin's
                      # volume group; empty: anywhere in that VG. To reserve a PV
                      # for snapshots: pvchange --allocatable n <pv>

# Healthchecks (use an instance that does not run on this server)
HCHK_SERVER_BACKUP=""
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
