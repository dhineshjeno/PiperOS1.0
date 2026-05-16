#!/bin/bash
# Rebuilds ONLY the ISO from the existing chroot — skips debootstrap.
# Run with: sudo bash /home/kratos/OS/piper-os/distro/rebuild-iso-only.sh

set -e

SCRIPT_DIR="/home/kratos/OS/piper-os/distro"
CHROOT_DIR="${SCRIPT_DIR}/work/chroot"
ISO_DIR="${SCRIPT_DIR}/work/iso"
OUTPUT_ISO="${SCRIPT_DIR}/piper-os-live.iso"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[PIPER]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Must be root
[ "$EUID" -ne 0 ] && error "Run as root: sudo bash $0"

# Chroot must exist
[ ! -f "${CHROOT_DIR}/bin/bash" ] && error "Chroot not found at ${CHROOT_DIR}. Run the full build first."

# Unmount anything left over
log "Cleaning up stale mounts..."
umount -lf "${CHROOT_DIR}/run"     2>/dev/null || true
umount -lf "${CHROOT_DIR}/sys"     2>/dev/null || true
umount -lf "${CHROOT_DIR}/proc"    2>/dev/null || true
umount -lf "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
umount -lf "${CHROOT_DIR}/dev"     2>/dev/null || true

# Fresh ISO directory
log "Creating clean ISO directory structure..."
rm -rf "${ISO_DIR}"
mkdir -p "${ISO_DIR}"/{casper,boot/grub,EFI/BOOT,.disk}

# Repack squashfs fresh from intact chroot
log "Repacking squashfs from chroot (this takes 10-30 min)..."
mksquashfs "${CHROOT_DIR}" "${ISO_DIR}/casper/filesystem.squashfs" \
    -comp xz -Xbcj x86 -b 1M -no-duplicates -no-recovery \
    -e "${CHROOT_DIR}/boot/vmlinuz-*" \
    -e "${CHROOT_DIR}/boot/initrd.img-*"

# Pick the standard Ubuntu kernel (not xanmod — more compatible with casper)
log "Copying kernel and initrd..."
KERNEL=$(ls "${CHROOT_DIR}"/boot/vmlinuz-*generic 2>/dev/null | sort -V | tail -1)
INITRD=$(ls "${CHROOT_DIR}"/boot/initrd.img-*generic 2>/dev/null | sort -V | tail -1)

# Fallback to any kernel if no generic found
if [ -z "$KERNEL" ]; then
    KERNEL=$(ls "${CHROOT_DIR}"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
    INITRD=$(ls "${CHROOT_DIR}"/boot/initrd.img-* 2>/dev/null | sort -V | tail -1)
fi

[ -z "$KERNEL" ] && error "No kernel found in ${CHROOT_DIR}/boot/"
[ -z "$INITRD" ] && error "No initrd found in ${CHROOT_DIR}/boot/"

log "  Kernel: $KERNEL"
log "  Initrd: $INITRD"

cp "$KERNEL" "${ISO_DIR}/casper/vmlinuz"
cp "$INITRD" "${ISO_DIR}/casper/initrd"

# Casper metadata
log "Writing casper metadata..."
du -sx --block-size=1 "${CHROOT_DIR}" | cut -f1 > "${ISO_DIR}/casper/filesystem.size"
chroot "${CHROOT_DIR}" dpkg-query -W --showformat='${Package} ${Version}\n' \
    > "${ISO_DIR}/casper/filesystem.manifest" 2>/dev/null || true

# Disk info
echo "Piper OS 1.1 focus - Live $(date +%Y%m%d)" > "${ISO_DIR}/.disk/info"
echo "full" > "${ISO_DIR}/.disk/cd_type"

# GRUB config — clean, no logo, auto-boots into live session after 5s
log "Writing grub.cfg..."
cat > "${ISO_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

insmod all_video
insmod gfxterm
set gfxmode=auto
terminal_output gfxterm

set color_normal=cyan/black
set color_highlight=white/black
set menu_color_normal=cyan/black
set menu_color_highlight=white/black

menuentry "Piper OS -- Live Session" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}

menuentry "Piper OS -- Safe Graphics (nomodeset)" {
    linux /casper/vmlinuz boot=casper nomodeset quiet splash ---
    initrd /casper/initrd
}
GRUB_CFG

# Build ISO
log "Building ISO with grub-mkrescue..."
grub-mkrescue \
    -o "${OUTPUT_ISO}" \
    "${ISO_DIR}" \
    -- -volid "PIPER_OS"

ISO_SIZE=$(du -h "${OUTPUT_ISO}" | cut -f1)
echo ""
log "========================================="
log "  DONE! ISO: ${OUTPUT_ISO}  (${ISO_SIZE})"
log "========================================="
echo ""
log "Boot command:"
echo "  qemu-system-x86_64 -m 4G -cdrom ${OUTPUT_ISO} -enable-kvm -net nic -net user"
