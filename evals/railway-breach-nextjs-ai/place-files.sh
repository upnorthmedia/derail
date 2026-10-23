#!/usr/bin/env bash
set -eu
cp -R "$(dirname "$0")/files/." .
chmod 700 migration/.secrets
chmod 600 migration/.secrets/railway.burned.sha256
