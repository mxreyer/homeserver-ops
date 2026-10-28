#!/bin/bash
# ==============================================================================
# Script Name: exports/paperless.sh
# Description: Creates a docker-agnostic export of documents, metadata and
#              database using the paperless "document exporter"
#              https://docs.paperless-ngx.com/administration/#exporter
#
# Notes:
#  - The exporter updates an existing export in place, so the export folder
#    does not need to be cleaned first.
#
# Restore instructions :
#   1. Extract the export folder from the borg archive.
#   2. Use the "document importer" https://docs.paperless-ngx.com/administration/#importer
#   3. Regenerate thumbnails and archives with document_thumbnails and document_archiver
# ==============================================================================

set -euo pipefail # exit on error, undef vars, or failed pipeline

echo "💾 Requesting paperless export..."
docker exec paperless-webserver-1 \
  document_exporter --delete --no-archive --no-thumbnail --no-progress-bar ../export
echo "✅ Export created successfully."
