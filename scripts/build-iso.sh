#!/usr/bin/env bash
set -euo pipefail

BUILD_ROOT="${1:-$(pwd)/build}"
ROOTFS="$BUILD_ROOT/rootfs"
ISO="$BUILD_ROOT/iso"
MOUNT="$BUILD_ROOT/mount"
INITRAMFS="$BUILD_ROOT/initramfs"

GENTOO_BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-openrc"
STAGE3_INFO_URL="$GENTOO_BASE/latest-stage3-amd64-openrc.txt"

rm -rf "$ROOTFS" "$ISO" "$MOUNT" "$INITRAMFS"
mkdir -p "$ROOTFS" "$ISO" "$MOUNT" "$INITRAMFS" "$ISO/boot" "$ISO/live"

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

echo "==> Installing kernel and initramfs build dependencies"
sudo apt-get update
sudo apt-get install -y linux-image-generic busybox-static cpio grub-pc-bin grub-common xorriso squashfs-tools

KERNEL="$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\n' | sort -V | tail -n1)"
if [[ -z "$KERNEL" ]]; then
  echo "ERROR: No installed Linux kernel found" >&2
  ls -la /boot >&2
  exit 1
fi
KVER="${KERNEL#vmlinuz-}"
MODULES="/lib/modules/$KVER"
if [[ ! -d "$MODULES" ]]; then
  echo "ERROR: Kernel modules for $KVER are missing" >&2
  exit 1
fi

echo "==> Using kernel $KERNEL"
# GitHub runners keep /boot root-readable; use sudo for the copy, then hand the
# build files back to the runner user.
sudo cp "/boot/$KERNEL" "$ISO/boot/vmlinuz"
sudo chown "$USER:$USER" "$ISO/boot/vmlinuz"

mkdir -p "$INITRAMFS"/{bin,dev,proc,sys,newroot,tmp,etc,lib/modules}
BUSYBOX="$(command -v busybox)"
cp "$BUSYBOX" "$INITRAMFS/bin/busybox"
for applet in sh mount umount switch_root modprobe mknod sleep losetup mkdir; do
  ln -sf busybox "$INITRAMFS/bin/$applet"
done

find_module() {
  local name="$1"
  find "$MODULES" -type f \( -name "$name.ko" -o -name "$name.ko.*" \) -print -quit
}

for name in loop squashfs isofs; do
  module="$(find_module "$name")"
  if [[ -z "$module" ]]; then
    echo "ERROR: Required kernel module not found: $name" >&2
    exit 1
  fi
  relative="${module#$MODULES/}"
  mkdir -p "$INITRAMFS/lib/modules/$KVER/$(dirname "$relative")"
  sudo cp "$module" "$INITRAMFS/lib/modules/$KVER/$relative"
  sudo chown "$USER:$USER" "$INITRAMFS/lib/modules/$KVER/$relative"
done

for name in cdrom; do
  module="$(find_module "$name")" || true
  if [[ -n "$module" ]]; then
    relative="${module#$MODULES/}"
    mkdir -p "$INITRAMFS/lib/modules/$KVER/$(dirname "$relative")"
    sudo cp "$module" "$INITRAMFS/lib/modules/$KVER/$relative"
    sudo chown "$USER:$USER" "$INITRAMFS/lib/modules/$KVER/$relative"
  fi
done

# Copy dependency metadata through sudo because it is root-readable on the runner.
if [[ -f "$MODULES/modules.dep" ]]; then
  sudo cp "$MODULES/modules.dep" "$INITRAMFS/lib/modules/$KVER/modules.dep"
  sudo chown "$USER:$USER" "$INITRAMFS/lib/modules/$KVER/modules.dep"
fi
if [[ -f "$MODULES/modules.alias" ]]; then
  sudo cp "$MODULES/modules.alias" "$INITRAMFS/lib/modules/$KVER/modules.alias"
  sudo chown "$USER:$USER" "$INITRAMFS/lib/modules/$KVER/modules.alias"
fi

cat > "$INITRAMFS/init" <<'EOF'
#!/bin/sh
set -eu
export PATH=/bin

mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t proc proc /proc
mount -t sysfs sysfs /sys

modprobe loop 2>/dev/null || true
modprobe isofs 2>/dev/null || true
modprobe squashfs 2>/dev/null || true

mkdir -p /cdrom /newroot

for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -b /dev/sr0 ] && break
    sleep 1
done

if [ ! -b /dev/sr0 ]; then
    echo "Rebuilt Gentoo: ISO device /dev/sr0 was not found."
    exec sh
fi

mount -t iso9660 -o ro /dev/sr0 /cdrom

if [ ! -f /cdrom/live/filesystem.squashfs ]; then
    echo "Rebuilt Gentoo: filesystem.squashfs was not found on the ISO."
    exec sh
fi

LOOP="$(losetup -f)"
losetup -r "$LOOP" /cdrom/live/filesystem.squashfs
mount -t squashfs -o ro "$LOOP" /newroot

mkdir -p /newroot/dev /newroot/proc /newroot/sys /newroot/run
mount --move /dev /newroot/dev
mount --move /proc /newroot/proc
mount --move /sys /newroot/sys

exec switch_root /newroot /sbin/init
EOF
chmod +x "$INITRAMFS/init"

(cd "$INITRAMFS" && find . -print0 | cpio --null -o -H newc | gzip -9 > "$ISO/boot/initramfs")

mkdir -p "$ISO/boot/grub" "$ISO/grub"
cat > "$ISO/boot/grub/grub.cfg" <<'EOF'
set timeout=5
set default=0

menuentry 'Rebuilt Gentoo' {
    linux /boot/vmlinuz boot=live
    initrd /boot/initramfs
}

menuentry 'Rebuilt Gentoo (safe graphics)' {
    linux /boot/vmlinuz boot=live nomodeset
    initrd /boot/initramfs
}
EOF

echo "==> Creating GRUB BIOS boot image"
GRUBDIR="$BUILD_ROOT/grub"
rm -rf "$GRUBDIR"
mkdir -p "$GRUBDIR"
grub-mkstandalone \
  -O i386-pc \
  -o "$GRUBDIR/core.img" \
  --modules="biosdisk iso9660 normal linux search search_fs_file" \
  "boot/grub/grub.cfg=$ISO/boot/grub/grub.cfg"
cp "$GRUBDIR/core.img" "$ISO/grub/core.img"

# Build a BIOS El Torito image. The GRUB core image is embedded directly as the
# El Torito boot image, so there is no reference to a nonexistent ISO path.
echo "==> Building bootable ISO"
xorriso -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -volid "REBUILT_GENTOO" \
  -b grub/core.img \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  -output "$ISO/Rebuilt-Gentoo-x86_64.iso" \
  "$ISO"

test -s "$ISO/boot/vmlinuz"
test -s "$ISO/boot/initramfs"
test -s "$ISO/live/filesystem.squashfs"
test -s "$ISO/grub/core.img"
test -s "$ISO/Rebuilt-Gentoo-x86_64.iso"

xorriso -indev "$ISO/Rebuilt-Gentoo-x86_64.iso" -report_el_torito plain

echo "==> Bootable Rebuilt Gentoo ISO created: $ISO/Rebuilt-Gentoo-x86_64.iso"
