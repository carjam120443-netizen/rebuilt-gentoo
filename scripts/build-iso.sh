#!/usr/bin/env bash
set -euo pipefail

BUILD_ROOT="${1:-$(pwd)/build}"
ROOTFS="$BUILD_ROOT/rootfs"
ISO="$BUILD_ROOT/iso"
INITRAMFS="$BUILD_ROOT/initramfs"

GENTOO_BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-openrc"
STAGE3_INFO_URL="$GENTOO_BASE/latest-stage3-amd64-openrc.txt"

rm -rf "$ROOTFS" "$ISO" "$INITRAMFS"
mkdir -p "$ROOTFS" "$ISO/boot" "$ISO/live" "$INITRAMFS"

echo "==> Resolving current Gentoo OpenRC stage3"
mkdir -p "$BUILD_ROOT/downloads"
STAGE3_INFO="$BUILD_ROOT/downloads/latest-stage3-amd64-openrc.txt"
curl -L --fail --retry 3 -o "$STAGE3_INFO" "$STAGE3_INFO_URL"
STAGE3_NAME="$(awk '/^stage3-amd64-openrc-[0-9].*\.tar\.xz [0-9]+$/ {print $1; exit}' "$STAGE3_INFO")"
[[ -n "$STAGE3_NAME" ]] || { echo "ERROR: Could not determine stage3 filename." >&2; exit 1; }
STAGE3="$BUILD_ROOT/downloads/$STAGE3_NAME"
echo "==> Downloading $STAGE3_NAME"
curl -L --fail --retry 3 --retry-delay 2 -o "$STAGE3" "$GENTOO_BASE/$STAGE3_NAME"

echo "==> Extracting stage3 (skipping device nodes)"
tar -xpf "$STAGE3" -C "$ROOTFS" --xattrs-include='*' --numeric-owner --exclude='./dev/*' --exclude='./dev'
mkdir -p "$ROOTFS/dev"

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

echo "==> Installing kernel and ISO build dependencies"
sudo apt-get update
sudo apt-get install -y linux-image-generic busybox-static cpio grub-pc-bin grub-common xorriso squashfs-tools

KERNEL="$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*-generic' -printf '%f\n' | sort -V | tail -n1)"
[[ -n "$KERNEL" ]] || { echo "ERROR: No installed generic Linux kernel found" >&2; ls -la /boot >&2; exit 1; }
KVER="${KERNEL#vmlinuz-}"
MODULES="/lib/modules/$KVER"
[[ -d "$MODULES" ]] || { echo "ERROR: Kernel modules for $KVER are missing" >&2; exit 1; }
echo "==> Using kernel $KERNEL"
sudo cp "/boot/$KERNEL" "$ISO/boot/vmlinuz"
sudo chown "$(id -u):$(id -g)" "$ISO/boot/vmlinuz"

mkdir -p "$INITRAMFS"/{bin,dev,proc,sys,newroot,tmp,etc,lib/modules}
BUSYBOX="$(command -v busybox)"
cp "$BUSYBOX" "$INITRAMFS/bin/busybox"
for applet in sh mount umount switch_root modprobe sleep losetup mkdir; do ln -sf busybox "$INITRAMFS/bin/$applet"; done

find_module() { find "$MODULES" -type f \( -name "$1.ko" -o -name "$1.ko.*" \) -print -quit; }
for name in loop squashfs isofs; do
  module="$(find_module "$name")"
  if [[ -z "$module" ]]; then
    case "$name" in
      loop) pattern='CONFIG_BLK_DEV_LOOP=y' ;;
      squashfs) pattern='CONFIG_SQUASHFS=y' ;;
      isofs) pattern='CONFIG_ISO9660_FS=y' ;;
    esac
    if grep -q "$pattern" "/boot/config-$KVER" 2>/dev/null; then
      echo "==> $name is built into kernel"
      continue
    fi
    echo "ERROR: Required kernel feature/module not found: $name" >&2
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
[ -f /cdrom/live/filesystem.squashfs ] || { echo "Rebuilt Gentoo: filesystem.squashfs was not found."; exec sh; }
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

mkdir -p "$ISO/boot/grub"
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

# Let xorriso build the BIOS El Torito GRUB image itself. grub-mkstandalone
# produces a standalone core image that is too large for the traditional
# 1.44MB/2.88MB El Torito boot image slot.
echo "==> Building bootable ISO with GRUB BIOS El Torito"
xorriso -as mkisofs \
  -iso-level 3 -full-iso9660-filenames \
  -volid "REBUILT_GENTOO" \
  -b boot/grub/i386-pc/eltorito.img \
  -c boot.catalog \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -output "$ISO/Rebuilt-Gentoo-x86_64.iso" \
  "$ISO"

for required in "$ISO/boot/vmlinuz" "$ISO/boot/initramfs" "$ISO/live/filesystem.squashfs" "$ISO/Rebuilt-Gentoo-x86_64.iso"; do
  test -s "$required" || { echo "ERROR: Missing build output: $required" >&2; exit 1; }
done

xorriso -indev "$ISO/Rebuilt-Gentoo-x86_64.iso" -report_el_torito plain
echo "==> Rebuilt Gentoo ISO created: $ISO/Rebuilt-Gentoo-x86_64.iso"
