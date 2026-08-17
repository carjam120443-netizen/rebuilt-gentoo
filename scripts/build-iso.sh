#!/usr/bin/env bash
set -euo pipefail

BUILD_ROOT="${1:-$(pwd)/build}"
ROOTFS="$BUILD_ROOT/rootfs"
ISO="$BUILD_ROOT/iso"
INITRAMFS="$BUILD_ROOT/initramfs"
DOWNLOADS="$BUILD_ROOT/downloads"

GENTOO_BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-openrc"
STAGE3_INFO_URL="$GENTOO_BASE/latest-stage3-amd64-openrc.txt"

rm -rf "$ROOTFS" "$ISO" "$INITRAMFS"
mkdir -p "$ROOTFS" "$ISO/boot" "$ISO/live" "$INITRAMFS" "$DOWNLOADS"

echo "==> Resolving current Gentoo OpenRC stage3"
STAGE3_INFO="$DOWNLOADS/latest-stage3-amd64-openrc.txt"
curl -L --fail --retry 3 --retry-delay 2 -o "$STAGE3_INFO" "$STAGE3_INFO_URL"
STAGE3_NAME="$(awk '/^stage3-amd64-openrc-[0-9].*\.tar\.xz [0-9]+$/ {print $1; exit}' "$STAGE3_INFO")"
[[ -n "$STAGE3_NAME" ]] || { echo "ERROR: Could not determine stage3 filename." >&2; exit 1; }
STAGE3="$DOWNLOADS/$STAGE3_NAME"
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
sudo apt-get install -y \
  linux-image-generic \
  busybox-static \
  cpio \
  kmod \
  zstd \
  grub-pc-bin \
  grub-efi-amd64-bin \
  grub-common \
  xorriso \
  squashfs-tools \
  rsync

KERNEL="$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*-generic' -printf '%f\n' | sort -V | tail -n1)"
[[ -n "$KERNEL" ]] || { echo "ERROR: No installed generic Linux kernel found" >&2; ls -la /boot >&2; exit 1; }
KVER="${KERNEL#vmlinuz-}"
MODULES="/lib/modules/$KVER"
[[ -d "$MODULES" ]] || { echo "ERROR: Kernel modules for $KVER are missing" >&2; exit 1; }
echo "==> Using kernel $KERNEL"

sudo cp "/boot/$KERNEL" "$ISO/boot/vmlinuz"
sudo chown "$(id -u):$(id -g)" "$ISO/boot/vmlinuz"

# Build a tiny initramfs containing the tools needed to locate the CD,
# mount its SquashFS payload, and hand control to the Gentoo userspace.
mkdir -p "$INITRAMFS"/{bin,dev,proc,sys,newroot,tmp,etc,lib/modules}
BUSYBOX="$(command -v busybox)"
cp "$BUSYBOX" "$INITRAMFS/bin/busybox"
for applet in sh mount umount switch_root modprobe sleep losetup mkdir insmod; do
  ln -sf busybox "$INITRAMFS/bin/$applet"
done

find_module() {
  find "$MODULES" -type f \( -name "$1.ko" -o -name "$1.ko.*" \) -print -quit
done
}

copy_module() {
  local name="$1" module relative dest
  module="$(find_module "$name")"
  [[ -n "$module" ]] || return 1
  relative="${module#$MODULES/}"
  dest="$INITRAMFS/lib/modules/$KVER/${relative%.zst}"
  mkdir -p "$(dirname "$dest")"
  if [[ "$module" == *.zst ]]; then
    zstd -q -d -f "$module" -o "$dest"
  else
    cp "$module" "$dest"
  fi
  sudo chown "$(id -u):$(id -g)" "$dest"
  echo "$name:$dest"
}

# loop, squashfs and isofs are the only filesystem/block features needed by
# this live boot path. Ubuntu's generic kernel normally has the first two
# built in; ISO9660 may be a module. We copy it into the initramfs and build a
# real modules.dep so BusyBox modprobe can load it reliably at boot.
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

  copy_module "$name" >/dev/null
  echo "==> Included kernel module: $name"
done

# cdrom is useful on physical optical drives but is not required for QEMU's
# virtual CD-ROM. Include it when available, without making it mandatory.
if find_module cdrom >/dev/null; then
  copy_module cdrom >/dev/null || true
fi

# Generate dependency metadata for the modules copied above. depmod may warn
# about optional metadata files absent from the tiny module tree; those warnings
# are harmless, but the generated modules.dep is required by BusyBox modprobe.
mkdir -p "$INITRAMFS/lib/modules/$KVER"
depmod -b "$INITRAMFS" "$KVER" || true

# The init script must be written literally. In particular, $(losetup -f) must
# execute inside the booted initramfs, not while this build script is running
# under `set -u`.
cat > "$INITRAMFS/init" <<'EOF'
#!/bin/sh
set -eu
export PATH=/bin

mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t proc proc /proc
mount -t sysfs sysfs /sys

# Load modules from our own initramfs module tree. Built-in modules simply
# return an error, which is harmless.
modprobe -d / loop 2>/dev/null || true
modprobe -d / isofs 2>/dev/null || true
modprobe -d / squashfs 2>/dev/null || true

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
    echo "Rebuilt Gentoo: filesystem.squashfs was not found."
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

# Compress the actual Gentoo userspace. This is the payload mounted by the
# initramfs above, and is what makes the ISO a real live Gentoo environment.
echo "==> Creating Gentoo live filesystem"
mksquashfs "$ROOTFS" "$ISO/live/filesystem.squashfs" \
  -comp xz \
  -noappend \
  -all-root \
  -e dev

mkdir -p "$ISO/boot/grub"
cat > "$ISO/boot/grub/grub.cfg" <<'EOF'
set timeout=5
set default=0

serial --unit=0 --speed=115200
terminal_input console serial
terminal_output console serial

menuentry 'Rebuilt Gentoo' {
    linux /boot/vmlinuz console=ttyS0,115200
    initrd /boot/initramfs
}

menuentry 'Rebuilt Gentoo (safe graphics)' {
    linux /boot/vmlinuz console=ttyS0,115200 nomodeset
    initrd /boot/initramfs
}
EOF

# grub-mkrescue creates both the BIOS El Torito image and the UEFI image from
# the ISO tree. Do not place the output ISO inside the source tree: doing so
# can make xorriso/grub recursively include its own output.
OUTPUT_ISO="$BUILD_ROOT/Rebuilt-Gentoo-x86_64.iso"
rm -f "$OUTPUT_ISO"
echo "==> Building bootable ISO with GRUB BIOS + UEFI"
grub-mkrescue \
  -o "$OUTPUT_ISO" \
  "$ISO"

# Keep the final ISO beside the source tree so the ISO cannot accidentally be
# included inside itself. The workflow uploads this file explicitly.
cp "$OUTPUT_ISO" "$ISO/Rebuilt-Gentoo-x86_64.iso"

for required in \
  "$ISO/boot/vmlinuz" \
  "$ISO/boot/initramfs" \
  "$ISO/live/filesystem.squashfs" \
  "$ISO/Rebuilt-Gentoo-x86_64.iso"; do
  test -s "$required" || {
    echo "ERROR: Missing build output: $required" >&2
    exit 1
  }
done

echo "==> Checking ISO El Torito metadata"
xorriso -indev "$ISO/Rebuilt-Gentoo-x86_64.iso" -report_el_torito plain

echo "==> Checking ISO contents"
xorriso -indev "$ISO/Rebuilt-Gentoo-x86_64.iso" -find /boot -type f -print | sed -n '1,80p'
xorriso -indev "$ISO/Rebuilt-Gentoo-x86_64.iso" -find /live -type f -print | sed -n '1,80p'

echo "==> Rebuilt Gentoo ISO created: $ISO/Rebuilt-Gentoo-x86_64.iso"
