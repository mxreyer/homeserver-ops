# Settings for the scripts in this repository. Backup settings (repositories,
# what to back up, retention, the backup healthcheck) live in
# /etc/borgmatic/config.yaml, see borgmatic/config.example.yaml.

# General
DOCKER_BINDS_DIR=""   # root of the containers' bind mounts, e.g. /srv/docker
DOCKER_COMPOSE_DIR="" # holds one <service>/compose.yaml per service
TS_DOMAIN=""
WEB_SERVICES=""       # space-separated; checked by webservice-health-ping.sh,
                      # and selects which exports/<service>.sh run before a backup
CONTAINER_STOP_TIMEOUT="" # optional; seconds containers get to shut down, defaults to 120
LOGS_DIR=""
STATE_DIR=""          # optional; defaults to /var/lib/homeserver-ops

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
