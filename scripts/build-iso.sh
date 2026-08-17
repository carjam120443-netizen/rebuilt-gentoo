#!/usr/bin/env bash
set -euo pipefail

BUILD_ROOT="${1:-$(pwd)/build}"
ROOTFS="$BUILD_ROOT/rootfs"
ISO="$BUILD_ROOT/iso"
MOUNT="$BUILD_ROOT/mount"

GENTOO_BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-openrc"
STAGE3_INFO_URL="$GENTOO_BASE/latest-stage3-amd64-openrc.txt"

rm -rf "$ROOTFS" "$ISO" "$MOUNT"
mkdir -p "$ROOTFS" "$ISO" "$MOUNT" "$ISO/boot" "$ISO/live"

# Resolve the current stage3 filename from Gentoo's latest manifest.
echo "==> Resolving current Gentoo OpenRC stage3"
mkdir -p "$BUILD_ROOT/downloads"
STAGE3_INFO="$BUILD_ROOT/downloads/latest-stage3-amd64-openrc.txt"
curl -L --fail --retry 3 -o "$STAGE3_INFO" "$STAGE3_INFO_URL"
STAGE3_NAME="$(awk '/^stage3-amd64-openrc-[0-9].*\.tar\.xz [0-9]+$/ {print $1; exit}' "$STAGE3_INFO")"
if [[ -z "$STAGE3_NAME" ]]; then
  echo "ERROR: Could not determine the current Gentoo stage3 filename." >&2
  cat "$STAGE3_INFO" >&2
  exit 1
fi
STAGE3_URL="$GENTOO_BASE/$STAGE3_NAME"
STAGE3="$BUILD_ROOT/downloads/$STAGE3_NAME"
echo "==> Downloading $STAGE3_NAME"
curl -L --fail --retry 3 --retry-delay 2 -o "$STAGE3" "$STAGE3_URL"

# GitHub-hosted runners do not permit creating device nodes during tar extraction.
# /dev is intentionally extracted as an empty directory; a real live kernel will
# populate it with devtmpfs when the system boots.
echo "==> Extracting stage3 (skipping device nodes)"
tar -xpf "$STAGE3" -C "$ROOTFS" \
  --xattrs-include='*' \
  --numeric-owner \
  --exclude='./dev/*' \
  --exclude='./dev'
mkdir -p "$ROOTFS/dev"

mkdir -p "$ROOTFS/etc"
cat > "$ROOTFS/etc/os-release" <<'EOF'
NAME="Rebuilt Gentoo"
ID="rebuilt-gentoo"
ID_LIKE="gentoo"
VERSION_ID="rolling"
PRETTY_NAME="Rebuilt Gentoo Rolling"
HOME_URL="https://github.com/carjam120443-netizen/rebuilt-gentoo"
EOF

cat > "$ROOTFS/etc/issue" <<'EOF'
\n\l

Rebuilt Gentoo Rolling
https://github.com/carjam120443-netizen/rebuilt-gentoo

EOF

cat > "$ROOTFS/etc/motd" <<'EOF'
   ____      _ _ _   _ ____  _ _   _
  |  _ \ ___| | | | | |  _ \(_) |_| |
  | |_) / _ \ | | | | | | | | | __| |
  |  _ <  __/ | | | |_| |_| | | |_| |
  |_| \_\___|_|_|_|\___/____/|_|\__|_|

              Rebuilt Gentoo
              Gentoo-based • Rebuilt for modern systems
EOF

if [[ -d branding ]]; then
  mkdir -p "$ROOTFS/usr/share/rebuilt-gentoo"
  rsync -a branding/ "$ROOTFS/usr/share/rebuilt-gentoo/branding/"
fi

echo "==> Creating SquashFS"
mksquashfs "$ROOTFS" "$ISO/live/filesystem.squashfs" -comp xz -noappend

mkdir -p "$ISO/boot/grub"
cat > "$ISO/boot/grub/grub.cfg" <<'EOF'
set timeout=5
set default=0

menuentry 'Rebuilt Gentoo' {
    linux /boot/vmlinuz
    initrd /boot/initrd
}

menuentry 'Rebuilt Gentoo (safe graphics)' {
    linux /boot/vmlinuz nomodeset
    initrd /boot/initrd
}
EOF

echo "Rebuilt Gentoo ISO filesystem prepared."

xorriso -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -volid "REBUILT_GENTOO" \
  -output "$ISO/Rebuilt-Gentoo-x86_64.iso" \
  "$ISO"

echo "==> ISO created: $ISO/Rebuilt-Gentoo-x86_64.iso"
