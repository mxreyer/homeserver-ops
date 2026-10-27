#!/bin/bash
# ==============================================================================
# Script Name: hooks/pkglist.sh
# Description: borgmatic command hook. Writes the installed package list to
#              /root/pkglist.txt so it ends up in the backup.
# ==============================================================================

set -euo pipefail

if command -v dpkg > /dev/null; then
  dpkg --get-selections > /root/pkglist.txt
elif command -v rpm > /dev/null; then
  rpm -qa --queryformat '%{NAME}\n' | sort -u > /root/pkglist.txt
else
  echo "⚠️ Neither dpkg nor rpm found, skipping package list."
fi
