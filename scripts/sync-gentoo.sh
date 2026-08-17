#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_URL="https://github.com/gentoo/gentoo.git"
UPSTREAM_REF="master"
WORKDIR="${TMPDIR:-/tmp}/rebuilt-gentoo-upstream"

rm -rf "$WORKDIR"
git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_URL" "$WORKDIR"

# Keep the upstream Gentoo tree isolated from Rebuilt Gentoo's own files.
mkdir -p gentoo
rsync -a --delete \
  --exclude='.git/' \
  "$WORKDIR/" gentoo/

rm -rf "$WORKDIR"

echo "Gentoo upstream tree synchronized into ./gentoo/"
