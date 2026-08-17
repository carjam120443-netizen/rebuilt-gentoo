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
if [[ -z "$STAGE3_NAME" ]]; then echo "ERROR: Could not determine stage3 filename." >&2; exit 1; fi
STAGE3_URL="$GENTOO_BASE/$STAGE3_NAME"
STAGE3="$BUILD_ROOT/downloads/$STAGE3_NAME"
echo "==> Downloading $STAGE3_NAME"
curl -L --fail --retry 3 --retry-delay 2 -o "$STAGE3" "$STAGE3_URL"

echo "==> Extracting stage3 (skipping device nodes)"
tar -xpf "$STAGE3" -C "$ROOTFS" --xattrs-include='*' --numeric-owner --exclude='./dev/*' --exclude='./dev'
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

# Use the generic Ubuntu kernel, not the Azure host kernel. The Azure kernel can
# omit the CD/SquashFS modules required by a live ISO.
KERNEL="$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*-generic' -printf '%f\n' | sort -V | tail -n1)"
if [[ -z "$KERNEL" ]]; then echo "ERROR: No installed generic Linux kernel found" >&2; ls -la /boot >&2; exit 1; fi
KVER="${KERNEL#vmlinuz-}"
MODULES="/lib/modules/$KVER"
if [[ ! -d "$MODULES" ]]; then echo "ERROR: Kernel modules for $KVER are missing" >&2; exit 1; fi
echo "==> Using kernel $KERNEL"
sudo cp "/boot/$KERNEL" "$ISO/boot/vmlinuz"
sudo chown "$(id -u):$(id -g)" "$ISO/boot/vmlinuz"

mkdir -p "$INITRAMFS"/{bin,dev,proc,sys,newroot,tmp,etc,lib/modules}
BUSYBOX="$(command -v busybox)"
cp "$BUSYBOX" "$INITRAMFS/bin/busybox"
for applet in sh mount umount switch_root modprobe mknod sleep losetup mkdir; do ln -sf busybox "$INITRAMFS/bin/$applet"; done

find_module() {
  local name="$1"
  find "$MODULES" -type f \( -name "$name.ko" -o -name "$name.ko.*" \) -print -quit
}

# Ubuntu generic kernels commonly built these as built-ins or place them under
# a subdirectory. If a needed feature is built in, no module is necessary.
for name in loop squashfs isofs; do
  module="$(find_module "$name")"
  if [[ -z "$module" ]]; then
    if grep -Eq "(^|[[:space:]])(CONFIG_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')|CONFIG_SQUASHFS|CONFIG_ISO9660_FS|CONFIG_BLK_DEV_LOOP)=(y)" "/boot/config-$KVER" 2>/dev/null; then
      echo "==> $name is built into kernel"
      continue
    fi
    echo "ERROR: Required kernel module not found: $name in $MODULES" >&2
    find "$MODULES" -type f -iname "*$name*" -print >&2 || true
    exit 1
  fi
  relative="${module#$MODULES/}"
  mkdir -p "$INITRAMFS/lib/modules/$KVER/$(dirname "$relative")"
  sudo cp "$module" "$INITRAMFS/lib/modules/$KVER/$relative"
  sudo chown "$(id -u):$(id -g)" "$INITRAMFS/lib/modules/$KVER/$relative"
done

module="$(find_module cdrom)"
if [[ -n "$module" ]]; then
  relative="${module#$MODULES/}"
  mkdir -p "$INITRAMFS/lib/modules/$KVER/$(dirname "$relative")"
  sudo cp "$module" "$INITRAMFS/lib/modules/$KVER/$relative"
  sudo chown "$(id -u):$(id -g)" "$INITRAMFS/lib/modules/$KVER/$relative"
fi

# Avoid copying the full dependency database: the tiny initramfs only needs
# the modules above, and modprobe can still be attempted without it.

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
for i in 1 2 3 4 5 6 7 8 9 10; do [ -b /dev/sr0 ] && break; sleep 1; done
if [ ! -b /dev/sr0 ]; then echo "Rebuilt Gentoo: ISO device /dev/sr0 was not found."; exec sh; fi
mount -t iso9660 -o ro /dev/sr0 /cdrom
if [ ! -f /cdrom/live/filesystem.squashfs ]; then echo "Rebuilt Gentoo: filesystem.squashfs was not found."; exec sh; fi
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
    linux /boot/vmlinuz
    initrd /boot/initramfs
}
menuentry 'Rebuilt Gentoo (safe graphics)' {
    linux /boot/vmlinuz nomodeset
    initrd /boot/initramfs
}
EOF

echo "==> Creating GRUB BIOS boot image"
GRUBDIR="$BUILD_ROOT/grub"
rm -rf "$GRUBDIR"
mkdir -p "$GRUBDIR"
grub-mkstandalone -O i386-pc -o "$GRUBDIR/core.img" --modules="biosdisk iso9660 normal linux search search_fs_file" "boot/grub/grub.cfg=$ISO/boot/grub/grub.cfg"
cp "$GRUBDIR/core.img" "$ISO/grub/core.img"

echo "==> Creating SquashFS"
mksquashfs "$ROOTFS" "$ISO/live/filesystem.squashfs" -comp xz -noappend

echo "==> Building bootable ISO"
xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames -volid "REBUILT_GENTOO" -b grub/core.img -no-emul-boot -boot-load-size 4 -boot-info-table -output "$ISO/Rebuilt-Gentoo-x86_64.iso" "$ISO"

for required in "$ISO/boot/vmlinuz" "$ISO/boot/initramfs" "$ISO/live/filesystem.squashfs" "$ISO/grub/core.img" "$ISO/Rebuilt-Gentoo-x86_64.iso"; do test -s "$required" || { echo "ERROR: Missing build output: $required" >&2; exit 1; }; done
xorriso -indev "$ISO/Rebuilt-Gentoo-x86_64.iso" -report_el_torito plain
echo "==> Bootable Rebuilt Gentoo ISO created: $ISO/Rebuilt-Gentoo-x86_64.iso"
