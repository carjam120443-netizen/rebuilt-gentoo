#!/usr/bin/env bash
set -euo pipefail

BUILD_ROOT="${1:-$(pwd)/build}"
ROOTFS="$BUILD_ROOT/rootfs"
ISO="$BUILD_ROOT/iso"
MOUNT="$BUILD_ROOT/mount"

GENTOO_MIRROR="https://distfiles.gentoo.org/releases/amd64/autobuilds/"
STAGE3_URL="${STAGE3_URL:-https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-openrc/stage3-amd64-openrc.tar.xz}"

rm -rf "$ROOTFS" "$ISO" "$MOUNT"
mkdir -p "$ROOTFS" "$ISO" "$MOUNT" "$ISO/boot" "$ISO/live"

echo "==> Downloading Gentoo OpenRC stage3"
mkdir -p "$BUILD_ROOT/downloads"
STAGE3="$BUILD_ROOT/downloads/stage3-amd64-openrc.tar.xz"
curl -L --fail --retry 3 -o "$STAGE3" "$STAGE3_URL"

echo "==> Extracting stage3"
tar -xpf "$STAGE3" -C "$ROOTFS" --xattrs-include='*' --numeric-owner

# Basic live-system configuration.
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

# Include branding resources when available.
if [[ -d branding ]]; then
  mkdir -p "$ROOTFS/usr/share/rebuilt-gentoo"
  rsync -a branding/ "$ROOTFS/usr/share/rebuilt-gentoo/branding/"
fi

# Copy a compressed root filesystem into the ISO.
echo "==> Creating SquashFS"
mksquashfs "$ROOTFS" "$ISO/live/filesystem.squashfs" -comp xz -noappend

# Minimal GRUB BIOS/UEFI boot image.
echo "==> Creating GRUB configuration"
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

# Kernel/initramfs are expected to be supplied by a later kernel stage.
# Keep placeholders out of the ISO rather than producing a falsely bootable image.
echo "Rebuilt Gentoo ISO filesystem prepared."

xorriso -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -volid "REBUILT_GENTOO" \
  -output "$ISO/Rebuilt-Gentoo-x86_64.iso" \
  "$ISO"

echo "==> ISO created: $ISO/Rebuilt-Gentoo-x86_64.iso"
