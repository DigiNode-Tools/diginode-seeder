#!/usr/bin/env bash
# DigiNode Seeder for Nito: https://seedsetup.nito.tools
#   curl -sSL https://seedsetup.nito.tools | sudo bash
# Downloads DigiNode Seeder (the same script as seedsetup.diginode.tools) and sets up Nito seeders
# only; seeders for other chains already on the server are kept. Options are passed on, e.g.:
#   curl -sSL https://seedsetup.nito.tools | sudo bash -s -- --help
set -euo pipefail
url="https://github.com/DigiNode-Tools/diginode-seeder-setup/releases/latest/download/diginode-seeder.sh"
tmp=$(mktemp /tmp/diginode-seeder.XXXXXX)
trap 'rm -f "$tmp"' EXIT
curl -fsSL "$url" -o "$tmp" || { echo "[✗] Couldn't download DigiNode Seeder from GitHub." >&2; exit 1; }
grep -q '^DGNS_VERSION=' "$tmp" || { echo "[✗] The download doesn't look like DigiNode Seeder." >&2; exit 1; }
bash "$tmp" --only nito "$@"
