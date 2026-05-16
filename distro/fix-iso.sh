#!/bin/bash
# Run with: sudo bash /home/kratos/OS/piper-os/distro/fix-iso.sh

ISO_DIR="/home/kratos/OS/piper-os/distro/work/iso"
CHROOT="/home/kratos/OS/piper-os/distro/work/chroot"
OUTPUT="/home/kratos/OS/piper-os/distro/piper-os-live.iso"

echo "[..] Copying kernel and initrd into casper/..."
mkdir -p "$ISO_DIR/casper"

KERNEL=$(ls "$CHROOT"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
INITRD=$(ls "$CHROOT"/boot/initrd.img-* 2>/dev/null | sort -V | tail -1)

echo "    Kernel: $KERNEL"
echo "    Initrd: $INITRD"

cp "$KERNEL" "$ISO_DIR/casper/vmlinuz"
cp "$INITRD" "$ISO_DIR/casper/initrd"

echo "[..] Writing grub.cfg..."
mkdir -p "$ISO_DIR/boot/grub"
cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=5
set default=0

insmod all_video
insmod gfxterm
set gfxmode=auto
terminal_output gfxterm

set color_normal=green/black
set color_highlight=white/dark-gray
set menu_color_normal=green/black
set menu_color_highlight=white/dark-gray

menuentry "Piper OS -- Live Session" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}

menuentry "Piper OS -- Safe Graphics" {
    linux /casper/vmlinuz boot=casper nomodeset quiet splash ---
    initrd /casper/initrd
}
GRUB_CFG

echo "[..] Rebuilding ISO..."
grub-mkrescue -o "$OUTPUT" "$ISO_DIR" -- -volid "PIPER_OS"

echo "[DONE] ISO ready: $OUTPUT"
echo "Boot: qemu-system-x86_64 -m 4G -cdrom $OUTPUT -enable-kvm -net nic -net user"
