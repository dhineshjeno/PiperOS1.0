#!/bin/bash
set -e

# Compile kernel
echo "Compiling kernel..."
as --32 boot.s -o boot.o
as --32 interrupts.s -o interrupts.o

# Helper to compile C files
compile_c() {
    gcc -m32 -c $1 -o $2 -std=gnu99 -ffreestanding -O2 -Wall -Wextra -fno-pic
}

compile_c kernel.c kernel.o
compile_c idt.c idt.o
compile_c isr.c isr.o
compile_c pic.c pic.o
compile_c keyboard.c keyboard.o
compile_c gdt.c gdt.o

echo "Linking..."
gcc -m32 -T linker.ld -o isodir/boot/kernel.bin -ffreestanding -O2 -nostdlib \
    boot.o interrupts.o kernel.o idt.o isr.o pic.o keyboard.o gdt.o -lgcc || \
    ld -m elf_i386 -T linker.ld -o isodir/boot/kernel.bin \
    boot.o interrupts.o kernel.o idt.o isr.o pic.o keyboard.o gdt.o

echo "Kernel built."

# Check for dependencies
if ! command -v grub-mkrescue &> /dev/null; then
    echo "Error: grub-mkrescue not found. Please install grub-common/grub-pc-bin."
    exit 1
fi
if ! command -v xorriso &> /dev/null; then
    echo "Error: xorriso not found."
    exit 1
fi

echo "Building Piper OS ISO..."

# Generate GRUB configuration
cat > isodir/boot/grub/grub.cfg << EOF
set timeout=0
set default=0

menuentry "Piper OS" {
    multiboot /boot/kernel.bin
    boot
}
EOF

# Generate ISO
grub-mkrescue -o piper-os.iso isodir/

echo "Build complete: piper-os.iso"
echo "To run in QEMU: qemu-system-x86_64 -cdrom piper-os.iso"
