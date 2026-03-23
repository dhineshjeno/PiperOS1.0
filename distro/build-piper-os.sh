#!/bin/bash
# ============================================================
#  Piper OS — Live ISO Build Script
#  Based on Ubuntu 24.04 LTS (Noble Numbat)
# ============================================================
set -e

# --- Configuration ---
DISTRO_NAME="Piper OS"
DISTRO_VERSION="1.0"
DISTRO_CODENAME="rattenfanger"
UBUNTU_CODENAME="noble"
ARCH="amd64"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/work"
CHROOT_DIR="${WORK_DIR}/chroot"
ISO_DIR="${WORK_DIR}/iso"
OUTPUT_ISO="${SCRIPT_DIR}/piper-os-live.iso"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[PIPER]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Pre-flight Checks ---
preflight() {
    log "Running pre-flight checks..."

    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root (use sudo)."
    fi

    for cmd in debootstrap mksquashfs xorriso grub-mkrescue; do
        if ! command -v "$cmd" &> /dev/null; then
            error "'$cmd' not found. Install it first."
        fi
    done

    # Check disk space (need at least 10GB free)
    AVAIL_GB=$(df --output=avail "${SCRIPT_DIR}" | tail -1 | awk '{print int($1/1048576)}')
    if [ "$AVAIL_GB" -lt 10 ]; then
        warn "Low disk space: ${AVAIL_GB}GB available. Recommended: 10GB+."
    fi

    log "Pre-flight checks passed. Available space: ${AVAIL_GB}GB"
}

# --- Phase 1: Bootstrap ---
bootstrap() {
    log "═══════════════════════════════════════════"
    log "  Phase 1: Bootstrapping Ubuntu ${UBUNTU_CODENAME}"
    log "═══════════════════════════════════════════"

    if [ -f "${CHROOT_DIR}/bin/bash" ]; then
        log "Existing bootstrap found. Skipping Phase 1 to save time..."
        return
    fi

    if [ -d "${CHROOT_DIR}" ]; then
        warn "Chroot directory exists but is incomplete. Cleaning up..."
        cleanup_mounts
        rm -rf "${CHROOT_DIR}"
    fi

    mkdir -p "${CHROOT_DIR}"

    log "Running debootstrap (this will take a few minutes)..."
    debootstrap \
        --arch="${ARCH}" \
        --components=main,restricted,universe,multiverse \
        "${UBUNTU_CODENAME}" \
        "${CHROOT_DIR}" \
        http://archive.ubuntu.com/ubuntu

    log "Bootstrap complete!"
}

# --- Phase 2: Configure chroot ---
configure_chroot() {
    log "═══════════════════════════════════════════"
    log "  Phase 2: Configuring the system"
    log "═══════════════════════════════════════════"

    # Mount essential filesystems
    mount_chroot

    # Copy DNS resolution (remove symlink first if it exists)
    rm -f "${CHROOT_DIR}/etc/resolv.conf"
    cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf"

    # --- Set up APT sources ---
    cat > "${CHROOT_DIR}/etc/apt/sources.list" << SOURCES
deb http://archive.ubuntu.com/ubuntu ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${UBUNTU_CODENAME}-security main restricted universe multiverse
SOURCES

    # --- Run configuration inside chroot ---
    cat > "${CHROOT_DIR}/tmp/configure.sh" << 'CHROOT_SCRIPT'
#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export HOME=/root
export LC_ALL=C

echo ">> Setting up locale..."
apt-get update
apt-get install -y locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

echo ">> Setting hostname..."
echo "piperos" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
127.0.1.1   piperos

::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

echo ">> Installing Linux kernel..."
apt-get install -y --no-install-recommends linux-generic linux-firmware

echo ">> Adding Mozilla Firefox official repo (real .deb, not snap)..."
apt-get install -y wget gnupg2
install -d -m 0755 /etc/apt/keyrings
wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O /etc/apt/keyrings/packages.mozilla.org.asc
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" > /etc/apt/sources.list.d/mozilla.list
cat > /etc/apt/preferences.d/mozilla << 'MOZPREF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
MOZPREF
apt-get update

echo ">> Installing desktop environment and packages..."
# Read the package list (skip comments and empty lines)
PACKAGES=""
while IFS= read -r line; do
    # Skip comments and empty lines
    line=$(echo "$line" | sed 's/#.*//' | xargs)
    [ -z "$line" ] && continue
    PACKAGES="$PACKAGES $line"
done < /tmp/packages.list

apt-get install -y $PACKAGES || {
    echo ">> Some packages failed, retrying with --fix-broken..."
    apt-get install -y --fix-broken
    apt-get install -y $PACKAGES || true
}

echo ">> Creating default user 'piper'..."
if ! id "piper" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo,audio,video,plugdev,users piper
fi
echo "piper:piper" | chpasswd
echo "piper ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/piper

echo ">> Configuring autologin for live session..."
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf << EOF
[Autologin]
User=piper
Session=plasma
EOF

echo ">> Setting up DBUS machine-id..."
dbus-uuidgen > /etc/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true

echo ">> Configuring network..."
mkdir -p /etc/NetworkManager
cat > /etc/NetworkManager/NetworkManager.conf << EOF
[main]
plugins=ifupdown,keyfile
dns=dnsmasq

[ifupdown]
managed=true
EOF
systemctl enable NetworkManager 2>/dev/null || true

echo ">> Configuring Plymouth boot splash..."
if command -v plymouth-set-default-theme &>/dev/null; then
    plymouth-set-default-theme spinner || true
fi

echo ">> Generating system initramfs..."
update-initramfs -c -k all || true

echo ">> Cleaning up..."
apt-get autoremove -y
apt-get clean
rm -rf /var/cache/apt/archives/*.deb
rm -rf /tmp/*
rm -f /etc/resolv.conf

echo ">> Chroot configuration complete!"
CHROOT_SCRIPT

    # Copy package list into chroot
    cp "${SCRIPT_DIR}/config/packages.list" "${CHROOT_DIR}/tmp/packages.list"

    # Run the configuration script
    chmod +x "${CHROOT_DIR}/tmp/configure.sh"
    chroot "${CHROOT_DIR}" /tmp/configure.sh

    log "Chroot configuration complete!"
}

# --- Phase 3: Apply Piper OS Branding ---
apply_branding() {
    log "═══════════════════════════════════════════"
    log "  Phase 3: Applying Piper OS branding"
    log "═══════════════════════════════════════════"

    # Custom os-release
    cp "${SCRIPT_DIR}/config/os-release" "${CHROOT_DIR}/etc/os-release"
    cp "${SCRIPT_DIR}/config/os-release" "${CHROOT_DIR}/usr/lib/os-release"

    # Set the LSB release info
    cat > "${CHROOT_DIR}/etc/lsb-release" << EOF
DISTRIB_ID=PiperOS
DISTRIB_RELEASE=${DISTRO_VERSION}
DISTRIB_CODENAME=${DISTRO_CODENAME}
DISTRIB_DESCRIPTION="${DISTRO_NAME} ${DISTRO_VERSION}"
EOF

    # Custom issue banner
    cat > "${CHROOT_DIR}/etc/issue" << EOF

    ╔═══════════════════════════════════╗
    ║         Welcome to Piper OS       ║
    ║     Built on Ubuntu ${UBUNTU_CODENAME}          ║
    ╚═══════════════════════════════════╝

EOF

    # Remove Ubuntu specific login messages (MOTD)
    rm -rf "${CHROOT_DIR}/etc/update-motd.d/"*
    rm -f "${CHROOT_DIR}/etc/motd"
    cat > "${CHROOT_DIR}/etc/update-motd.d/00-piper-os" << 'MOTD'
#!/bin/sh
echo "Welcome to Piper OS 1.0"
echo "Project Pied Piper Core System"
MOTD
    chmod +x "${CHROOT_DIR}/etc/update-motd.d/00-piper-os"

    # Custom Boot Splash Image
    # Look for the logo the user placed in the config directory
    if [ -f "${SCRIPT_DIR}/config/piper-logo.png" ]; then
        log "Applying Piper OS custom boot splash logo..."
        
        # Backup original
        mv "${CHROOT_DIR}/usr/share/plymouth/themes/spinner/bgrt-fallback.png" "${CHROOT_DIR}/usr/share/plymouth/themes/spinner/bgrt-fallback.png.bak" 2>/dev/null || true
        mv "${CHROOT_DIR}/usr/share/plymouth/themes/spinner/watermark.png" "${CHROOT_DIR}/usr/share/plymouth/themes/spinner/watermark.png.bak" 2>/dev/null || true
        
        # Replace with our Pied Piper logo
        cp "${SCRIPT_DIR}/config/piper-logo.png" "${CHROOT_DIR}/usr/share/plymouth/themes/spinner/bgrt-fallback.png"
        cp "${SCRIPT_DIR}/config/piper-logo.png" "${CHROOT_DIR}/usr/share/plymouth/themes/spinner/watermark.png"
        
        # Re-pack the initramfs to include the new boot logo
        chroot "${CHROOT_DIR}" update-initramfs -u
    else
        warn "Could not find 'config/piper-logo.png'. Skipping custom boot logo."
    fi

    log "Branding applied!"
}

# --- Phase 4: Build the ISO ---
build_iso() {
    log "═══════════════════════════════════════════"
    log "  Phase 4: Building the live ISO"
    log "═══════════════════════════════════════════"

    # Unmount chroot filesystems
    cleanup_mounts

    # Create ISO directory structure
    rm -rf "${ISO_DIR}"
    mkdir -p "${ISO_DIR}"/{casper,boot/grub,EFI/BOOT,.disk}

    # --- Create squashfs (compressed root filesystem) ---
    log "Creating squashfs filesystem (this takes a while)..."
    mksquashfs "${CHROOT_DIR}" "${ISO_DIR}/casper/filesystem.squashfs" \
        -comp xz -Xbcj x86 -b 1M -no-duplicates -no-recovery \
        -e "${CHROOT_DIR}/boot/vmlinuz-*" \
        -e "${CHROOT_DIR}/boot/initrd.img-*"

    # --- Copy kernel and initrd ---
    log "Copying kernel and initramfs..."
    KERNEL=$(ls "${CHROOT_DIR}"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
    INITRD=$(ls "${CHROOT_DIR}"/boot/initrd.img-* 2>/dev/null | sort -V | tail -1)

    if [ -z "$KERNEL" ] || [ -z "$INITRD" ]; then
        error "Could not find kernel or initrd in chroot!"
    fi

    cp "$KERNEL" "${ISO_DIR}/casper/vmlinuz"
    cp "$INITRD" "${ISO_DIR}/casper/initrd"

    # --- filesystem.size (needed by casper) ---
    du -sx --block-size=1 "${CHROOT_DIR}" | cut -f1 > "${ISO_DIR}/casper/filesystem.size"

    # --- filesystem.manifest (list of installed packages) ---
    chroot "${CHROOT_DIR}" dpkg-query -W --showformat='${Package} ${Version}\n' \
        > "${ISO_DIR}/casper/filesystem.manifest" 2>/dev/null || true

    # --- .disk info ---
    echo "${DISTRO_NAME} ${DISTRO_VERSION} \"${DISTRO_CODENAME}\" - Live $(date +%Y%m%d)" \
        > "${ISO_DIR}/.disk/info"
    echo "full" > "${ISO_DIR}/.disk/cd_type"

    # --- GRUB configuration ---
    cat > "${ISO_DIR}/boot/grub/grub.cfg" << 'GRUB_CFG'
set timeout=10
set default=0

# Load video modules
insmod all_video
insmod gfxterm
set gfxmode=auto
terminal_output gfxterm

# Piper OS color scheme
set color_normal=green/black
set color_highlight=white/dark-gray
set menu_color_normal=green/black
set menu_color_highlight=white/dark-gray

menuentry "Piper OS — Live Session" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}

menuentry "Piper OS — Live Session (Safe Graphics)" {
    linux /casper/vmlinuz boot=casper nomodeset quiet splash ---
    initrd /casper/initrd
}

menuentry "Check disc for defects" {
    linux /casper/vmlinuz boot=casper integrity-check quiet splash ---
    initrd /casper/initrd
}

menuentry "Memory test (memtest86+)" {
    linux16 /boot/memtest86+.bin
}
GRUB_CFG

    # --- Build the ISO ---
    log "Building ISO image..."
    grub-mkrescue \
        -o "${OUTPUT_ISO}" \
        "${ISO_DIR}" \
        -- -volid "PIPER_OS"

    ISO_SIZE=$(du -h "${OUTPUT_ISO}" | cut -f1)
    log "═══════════════════════════════════════════"
    log "  ✅ Build complete!"
    log "  ISO: ${OUTPUT_ISO}"
    log "  Size: ${ISO_SIZE}"
    log "═══════════════════════════════════════════"
    log ""
    log "  To test: qemu-system-x86_64 -m 2G -cdrom ${OUTPUT_ISO} -enable-kvm"
}

# --- Helper: Mount chroot filesystems ---
mount_chroot() {
    log "Mounting chroot filesystems..."
    mount --bind /dev "${CHROOT_DIR}/dev" 2>/dev/null || true
    mount --bind /dev/pts "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
    mount -t proc proc "${CHROOT_DIR}/proc" 2>/dev/null || true
    mount -t sysfs sysfs "${CHROOT_DIR}/sys" 2>/dev/null || true
    mount -t tmpfs tmpfs "${CHROOT_DIR}/run" 2>/dev/null || true
}

# --- Helper: Cleanup mounts ---
cleanup_mounts() {
    log "Unmounting chroot filesystems..."
    umount -lf "${CHROOT_DIR}/run" 2>/dev/null || true
    umount -lf "${CHROOT_DIR}/sys" 2>/dev/null || true
    umount -lf "${CHROOT_DIR}/proc" 2>/dev/null || true
    umount -lf "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
    umount -lf "${CHROOT_DIR}/dev" 2>/dev/null || true
}

# --- Cleanup on exit ---
cleanup() {
    if [ $? -ne 0 ]; then
        warn "Build failed! Cleaning up mounts..."
        cleanup_mounts
    fi
}
trap cleanup EXIT

# --- Main ---
main() {
    echo -e "${CYAN}"
    echo "  ╔═══════════════════════════════════════════╗"
    echo "  ║                                           ║"
    echo "  ║     🎵  Piper OS Build System  🎵         ║"
    echo "  ║         v${DISTRO_VERSION} — Based on Ubuntu ${UBUNTU_CODENAME}      ║"
    echo "  ║                                           ║"
    echo "  ╚═══════════════════════════════════════════╝"
    echo -e "${NC}"

    preflight
    bootstrap
    configure_chroot
    apply_branding
    build_iso

    log "🎉 Piper OS is ready!"
}

main "$@"
