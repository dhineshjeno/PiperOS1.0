#!/bin/bash
# ============================================================
#  Piper OS — Live ISO Build Script
#  Based on Ubuntu 24.04 LTS (Noble Numbat)
# ============================================================
set -e

# --- Configuration ---
DISTRO_NAME="Piper OS [Focus Edition]"
DISTRO_VERSION="1.1"
DISTRO_CODENAME="focus"
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
set -o pipefail

export DEBIAN_FRONTEND=noninteractive
export HOME=/root
export LC_ALL=C

echo ">> Cleaning old repository artifacts..."
rm -f /etc/apt/sources.list.d/xanmod-release.list 2>/dev/null || true
rm -rf /var/lib/apt/lists/*
apt-get clean

echo ">> Fixing chroot specific package issues..."
apt-get update
# Remove and hold ubuntu-pro-client as it fails to configure in chroot
apt-get purge -y ubuntu-pro-client ubuntu-pro-client-l10n ubuntu-advantage-tools || true
apt-mark hold ubuntu-pro-client ubuntu-pro-client-l10n ubuntu-advantage-tools || true
# Install zstd to fix initramfs warnings
apt-get install -y zstd locales

echo ">> Setting up locale..."
apt-get full-upgrade -y --allow-downgrades
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

echo ">> Installing kernel and essential firmware..."
apt-get update
apt-get install -y --no-install-recommends linux-generic linux-firmware

echo ">> Adding Mozilla Firefox official repo..."
# Attempt to use the official repo, but clean it first
rm -f /etc/apt/sources.list.d/mozilla.list
apt-get install -y wget gnupg2 curl
install -d -m 0755 /etc/apt/keyrings
wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O /etc/apt/keyrings/packages.mozilla.org.asc
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" > /etc/apt/sources.list.d/mozilla.list
cat > /etc/apt/preferences.d/mozilla << 'MOZPREF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
MOZPREF
apt-get update || {
    echo ">> [WARN] Mozilla repo failed. Rolling back to Ubuntu default Firefox..."
    rm -f /etc/apt/sources.list.d/mozilla.list
    apt-get update
}

echo ">> Installing desktop environment and packages..."
# Read the package list (skip comments and empty lines)
PACKAGES=""
while IFS= read -r line; do
    # Skip comments and empty lines
    line=$(echo "$line" | sed 's/#.*//' | xargs)
    [ -z "$line" ] && continue
    PACKAGES="$PACKAGES $line"
done < /tmp/packages.list

apt-get install -y --allow-downgrades $PACKAGES || {
    echo ">> Some packages failed, retrying with --fix-broken..."
    apt-get install -y --fix-broken
    apt-get install -y --allow-downgrades $PACKAGES || true
}

echo ">> Installing Spotify Official Client..."
# Use the manually downloaded key from the host if it exists, otherwise attempt download
if [ -f "${SCRIPT_DIR}/spotify.gpg" ]; then
    echo ">> Using local spotify.gpg key provided by user."
    cp "${SCRIPT_DIR}/spotify.gpg" "${CHROOT_DIR}/etc/apt/keyrings/spotify.gpg"
else
    echo ">> Downloading Spotify GPG key..."
    curl -fsSL https://download.spotify.com/debian/pubkey_5384CE82BA52C83A.asc | gpg --dearmor --yes -o /etc/apt/keyrings/spotify.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/spotify.gpg] http://repository.spotify.com stable non-free" > /etc/apt/sources.list.d/spotify.list
apt-get update
apt-get install -y spotify-client

echo ">> Finalizing Desktop Environment..."
# Ensure KDE is the preferred session and remove any accidental xfce components
apt-get purge -y xfce4* xfwm4* 2>/dev/null || true
apt-get autoremove -y
update-alternatives --set x-session-manager /usr/bin/startplasma-x11 2>/dev/null || true

echo ">> Creating focus-optimized user 'piper'..."
if ! id "piper" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo,audio,video,plugdev,users piper
fi
echo "piper:piper" | chpasswd
echo "piper ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/piper

echo ">> Configuring shell and terminal branding..."

# Wipe any old MOTDs / profile.d welcome scripts from previous builds
echo "" > /etc/motd
rm -f /etc/update-motd.d/10-help-text
rm -f /etc/update-motd.d/50-motd-news
rm -f /etc/profile.d/piper-welcome.sh 2>/dev/null || true
rm -f /etc/profile.d/piper-motd.sh 2>/dev/null || true

# --- Bash prompt + fastfetch greeting (overwrite, not append) ---
cat > /home/piper/.bashrc << 'PROMPT'
# ── Piper OS Shell ──────────────────────────────────────────
PS1='\[\e[38;5;39m\]\u@piperos\[\e[0m\]:\[\e[1;36m\]\w\[\e[0m\] $ '

# Show system info on terminal open
fastfetch 2>/dev/null || true

# Aliases
alias focus-mode='systemctl stop cron 2>/dev/null; spotify & echo "Focus mode on."'
alias clocks='gnome-clocks'
alias spotify='spotify &'

# Remove any old repeating welcome messages from bashrc
sed -i '/Welcome to Piper OS Terminal/d' /home/piper/.bashrc 2>/dev/null || true
sed -i '/Essential Linux Commands/d' /home/piper/.bashrc 2>/dev/null || true
sed -i '/Piper Security/d' /home/piper/.bashrc 2>/dev/null || true

# ────────────────────────────────────────────────────────────
PROMPT
chown piper:piper /home/piper/.bashrc


# --- Konsole: Piper OS dark colour scheme (matches website mockup) ---
mkdir -p /home/piper/.local/share/konsole

cat > /home/piper/.local/share/konsole/PiperOS.colorscheme << 'COLORSCHEME'
[Background]
Color=15,17,23

[BackgroundIntense]
Color=28,35,46

[Color0]
Color=30,41,59

[Color0Intense]
Color=51,65,85

[Color1]
Color=248,113,113

[Color1Intense]
Color=252,165,165

[Color2]
Color=34,197,94

[Color2Intense]
Color=74,222,128

[Color3]
Color=250,204,21

[Color3Intense]
Color=253,224,71

[Color4]
Color=59,130,246

[Color4Intense]
Color=96,165,250

[Color5]
Color=168,85,247

[Color5Intense]
Color=192,132,252

[Color6]
Color=103,232,249

[Color6Intense]
Color=165,243,252

[Color7]
Color=148,163,184

[Color7Intense]
Color=226,232,240

[Foreground]
Color=203,213,225

[ForegroundIntense]
Color=241,245,249

[ForegroundFaint]
Color=100,116,139

[General]
Blur=true
ColorRandomization=false
Description=Piper OS Dark
Opacity=0.92
Wallpaper=
COLORSCHEME

# --- Konsole: default profile ---
cat > /home/piper/.local/share/konsole/PiperOS.profile << 'PROFILE'
[Appearance]
ColorScheme=PiperOS
Font=Monospace,11,-1,5,50,0,0,0,0,0

[General]
Command=/bin/bash
Name=Piper OS
Parent=FALLBACK/
TerminalColumns=120
TerminalRows=35

[Scrolling]
HistoryMode=2
HistorySize=10000

[Terminal Features]
BlinkingCursorEnabled=true
CursorShape=0
PROFILE

# Set as default Konsole profile
mkdir -p /home/piper/.config
cat > /home/piper/.config/konsolerc << 'KONSOLERC'
[Desktop Entry]
DefaultProfile=PiperOS.profile

[MainWindow]
MenuBar=Disabled
ToolBarsMovable=Disabled
KONSOLERC

chown -R piper:piper /home/piper/.local /home/piper/.config


cat >> /root/.bashrc << 'PROMPT'
# Root Focus Prompt
PS1='\[\e[31m\]# \[\e[1;37m\]\w\[\e[0m\] # '

# --- Piper OS Focus Mode ---
echo -e "\n\e[1;31mWelcome to Piper OS ROOT Control\e[0m"
echo -e "\e[1;33mSystem Administration for Study Mastery\e[0m\n"
PROMPT

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
cat << 'EOM'
    ____  _                         ____  _____ 
   / __ \(_)___  ___  _____        / __ \/ ___/ 
  / /_/ / / __ \/ _ \/ ___/______ / / / /\__ \  
 / ____/ / /_/ /  __/ /  /_____// /_/ /___/ /  
/_/   /_/ .___/\___/_/          \____//____/   
       /_/   [ Focus Edition ]

EOM
echo "Welcome to Piper OS 1.1 - Distraction-Free Study Environment"
echo "Spotify, Anki, and Productivity Toolkit Loaded."
MOTD
    chmod +x "${CHROOT_DIR}/etc/update-motd.d/00-piper-os"

    # --- Plymouth ASCII Animation Boot Theme ---
    log "Installing Piper OS ASCII Plymouth boot theme..."
    mkdir -p "${CHROOT_DIR}/usr/share/plymouth/themes/piper-ascii"

    cat > "${CHROOT_DIR}/usr/share/plymouth/themes/piper-ascii/piper-ascii.plymouth" << 'PLYMOUTHCFG'
[Plymouth Theme]
Name=Piper ASCII
Description=Piper OS ASCII Boot Animation
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/piper-ascii
ScriptFile=/usr/share/plymouth/themes/piper-ascii/piper-ascii.script
PLYMOUTHCFG

    cat > "${CHROOT_DIR}/usr/share/plymouth/themes/piper-ascii/piper-ascii.script" << 'PLYMOUTHSCRIPT'
Window.SetBackgroundTopColor(0.059, 0.059, 0.090);
Window.SetBackgroundBottomColor(0.020, 0.020, 0.050);

cx = Window.GetWidth() / 2;
cy = Window.GetHeight() / 2;

blue_r = 0.231; blue_g = 0.510; blue_b = 0.961;
dim_r  = 0.250; dim_g  = 0.350; dim_b  = 0.500;

fun make_line(txt, r, g, b) {
    return Image.Text(txt, r, g, b, "Monospace Bold 9");
}

lines[0] = " _____ _                 ___  ___ ";
lines[1] = "|  __ (_)               / _ \\/ __|";
lines[2] = "| |__) | _ __   ___ _ _| | | \\__ \\";
lines[3] = "|  ___/ | '_ \\ / _ \\ '__| | | |__) |";
lines[4] = "|_|   |_| .__/ \\___|_|  \\___/|____/";
lines[5] = "        | |                       ";
lines[6] = "        |_|                       ";

for (i = 0; i < 7; i++) {
    img = make_line(lines[i], blue_r, blue_g, blue_b);
    sp = Sprite(img);
    sp.SetX(cx - 160);
    sp.SetY(cy - 80 + i * 20);
    sp.SetOpacity(0.0);
    logo_sprites[i] = sp;
    logo_imgs[i] = img;
}

dot_sprite = Sprite();
dot_sprite.SetX(cx - 30);
dot_sprite.SetY(cy + 50);

frame = 0;
fade_done = 0;

fun refresh_callback() {
    frame++;

    # Fade in logo
    if (frame <= 30) {
        opacity = frame / 30.0;
        for (i = 0; i < 7; i++) {
            logo_sprites[i].SetOpacity(opacity);
        }
    }

    # Animate dots
    local.mod = Math.Int(frame / 12) % 4;
    local.dots = "";
    for (j = 0; j < local.mod; j++) { local.dots = local.dots + "."; }
    local.dimg = make_line("Booting" + local.dots, dim_r, dim_g, dim_b);
    dot_sprite.SetImage(local.dimg);
    dot_sprite.SetX(cx - local.dimg.GetWidth() / 2);
}

Plymouth.SetRefreshFunction(refresh_callback);
PLYMOUTHSCRIPT

    # Install and activate the theme inside chroot
    mount_chroot
    chroot "${CHROOT_DIR}" /bin/bash -c "
        # Try multiple possible locations for plymouth tool
        PLYMOUTH_CMD=''
        for p in /usr/sbin/plymouth-set-default-theme /usr/bin/plymouth-set-default-theme /sbin/plymouth-set-default-theme; do
            [ -x \"\$p\" ] && PLYMOUTH_CMD=\"\$p\" && break
        done
        if [ -n \"\$PLYMOUTH_CMD\" ]; then
            \$PLYMOUTH_CMD piper-ascii
            echo 'Plymouth theme set to piper-ascii'
        else
            # Manually write the default theme config
            echo 'piper-ascii' > /etc/plymouth/plymouthd.conf.d/default-theme 2>/dev/null || true
            mkdir -p /etc/plymouth
            printf '[Daemon]\nTheme=piper-ascii\nShowDelay=0\n' > /etc/plymouth/plymouthd.conf
            echo 'Plymouth theme configured manually'
        fi
        update-initramfs -u 2>/dev/null || true
    "
    cleanup_mounts

    # --- Strip Ubuntu Defaults & Apply Piper OS Aesthetics ---
    log "Removing Ubuntu branding and applying Piper OS visuals..."

    # Nuke Ubuntu wallpapers — replace them all with our own
    mkdir -p "${CHROOT_DIR}/usr/share/backgrounds"
    rm -f "${CHROOT_DIR}/usr/share/backgrounds/ubuntu-default"* 2>/dev/null || true
    rm -f "${CHROOT_DIR}/usr/share/backgrounds/warty-final"* 2>/dev/null || true

    # Generate a branded Piper OS wallpaper using Python + Pillow (if available)
    # Otherwise fall back to ImageMagick, otherwise plain dark.
    cat > "${CHROOT_DIR}/tmp/gen_wallpaper.py" << 'WALLPAPER_PY'
import sys
try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit(1)

W, H = 1920, 1080
img = Image.new('RGB', (W, H))
draw = ImageDraw.Draw(img)

# Dark gradient background
for y in range(H):
    t = y / H
    r = int(15 + (30 - 15) * t)
    g = int(17 + (41 - 17) * t)
    b = int(23 + (59 - 23) * t)
    draw.line([(0, y), (W, y)], fill=(r, g, b))

# Subtle blue accent circle
for i in range(8):
    c = 255 - i * 30
    draw.ellipse([W//2-200+i, H//2-200+i, W//2+200-i, H//2+200-i],
                 outline=(59, 130, c), width=1)

# ASCII logo text
logo = [
    "  ____  _                         ____  _____",
    " / __ \(i)___  ___  _____        / __ \/ ___ /",
    "/ /_/ / / __ \/ _ \/ ___/ ____  / / / /\\__ \\",
    "\\____/_/ .___/\\___/_/   /____/ \\____//____/",
    "       /_/     Focus Edition v1.1",
]
try:
    font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf', 22)
    small = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', 14)
except:
    font = ImageFont.load_default()
    small = font

y_start = H // 2 - 80
for i, line in enumerate(logo):
    bbox = draw.textbbox((0,0), line, font=font)
    tw = bbox[2] - bbox[0]
    draw.text(((W - tw) // 2, y_start + i * 30), line, fill=(59, 130, 246), font=font)

# Tagline
tag = "A Linux OS that just works."
bbox = draw.textbbox((0,0), tag, font=small)
tw = bbox[2] - bbox[0]
draw.text(((W - tw) // 2, y_start + 190), tag, fill=(100, 116, 139), font=small)

img.save('/usr/share/backgrounds/piper-wallpaper.png')
print("Wallpaper generated with Pillow.")
WALLPAPER_PY

    chroot "${CHROOT_DIR}" /bin/bash -c "
        python3 /tmp/gen_wallpaper.py 2>/dev/null || \
        convert -size 1920x1080 gradient:'#0f1117-#1e293b' \
            -font DejaVu-Sans-Mono-Bold -pointsize 32 \
            -fill '#3b82f6' -gravity center \
            -annotate 0 'PIPER OS\nFocus Edition v1.1' \
            /usr/share/backgrounds/piper-wallpaper.png 2>/dev/null || \
        convert -size 1920x1080 xc:'#0f1117' /usr/share/backgrounds/piper-wallpaper.png 2>/dev/null || true
        rm -f /tmp/gen_wallpaper.py
    "

    # KDE Plasma wallpaper config for live user
    mkdir -p "${CHROOT_DIR}/etc/skel/.config"
    cat > "${CHROOT_DIR}/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc" << 'KDEWP'
[Containments][1]
wallpaperplugin=org.kde.image
[Containments][1][Wallpaper][org.kde.image][General]
Image=file:///usr/share/backgrounds/piper-wallpaper.png
Color=982555F9
KDEWP

    # KDE globals — dark theme, no Ubuntu look
    cat > "${CHROOT_DIR}/etc/skel/.config/kdeglobals" << 'KDEGLOBALS'
[KDE]
lookAndFeelPackage=org.kde.breezedark.desktop
widgetStyle=Breeze

[General]
ColorScheme=BreezeDark

[Icons]
Theme=Papirus-Dark
KDEGLOBALS

    # SDDM: dark theme, no Ubuntu branding on login screen
    mkdir -p "${CHROOT_DIR}/etc/sddm.conf.d"
    cat > "${CHROOT_DIR}/etc/sddm.conf.d/theme.conf" << 'SDDMTHEME'
[Theme]
Current=breeze
CursorTheme=breeze_cursors
Font=Outfit,10,-1,5,50,0,0,0,0,0
SDDMTHEME

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
    log "  To test: qemu-system-x86_64 -m 4G -cdrom ${OUTPUT_ISO} -enable-kvm -net nic -net user"
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
