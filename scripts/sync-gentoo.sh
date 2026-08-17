#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_URL="https://github.com/gentoo/gentoo.git"
UPSTREAM_REF="master"
WORKDIR="${TMPDIR:-/tmp}/rebuilt-gentoo-upstream"

rm -rf "$WORKDIR"
git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_URL" "$WORKDIR"

# Keep Rebuilt Gentoo's project files while importing the Gentoo package tree.
rsync -a --delete \
  --exclude='.git/' \
  --exclude='.github/' \
  --exclude='README.md' \
  "$WORKDIR/" ./

rm -rf "$WORKDIR"

echo "Gentoo upstream tree synchronized."
