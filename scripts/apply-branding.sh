#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-}"
if [[ -z "$ROOT" ]]; then
  echo "Usage: $0 <target-root>"
  exit 2
fi

mkdir -p "$ROOT/etc" "$ROOT/usr/share/rebuilt-gentoo" "$ROOT/usr/share/backgrounds/rebuilt-gentoo"

cp branding/etc/os-release "$ROOT/etc/os-release.rebuilt-gentoo"
cp branding/etc/issue "$ROOT/etc/issue"
cp branding/etc/motd "$ROOT/etc/motd"
cp branding/usr/share/rebuilt-gentoo/branding.conf "$ROOT/usr/share/rebuilt-gentoo/branding.conf"

if [[ -d branding/usr/share/backgrounds/rebuilt-gentoo ]]; then
  cp -a branding/usr/share/backgrounds/rebuilt-gentoo/. "$ROOT/usr/share/backgrounds/rebuilt-gentoo/"
fi

echo "Applied Rebuilt Gentoo branding to $ROOT"
