Piper OS — Documentation
What is Piper OS?

Piper OS is a custom Linux distribution based on Ubuntu 24.04 LTS (Noble Numbat). It uses the real Linux kernel and ships with the XFCE4 desktop environment, custom branding, and a curated set of pre-installed software — packaged as a bootable live ISO.
Current Build Status (Phase 1 of 4 — in progress)
Phase 	Description 	Status
1. Bootstrap 	Download minimal Ubuntu Noble base system 	🔄 Running
2. Configure 	Install kernel, XFCE4 desktop, apps, create user 	⏳ Pending
3. Brand 	Apply Piper OS name, banners, theming 	⏳ Pending
4. Build ISO 	Compress filesystem + create bootable ISO 	⏳ Pending
What's Inside Piper OS
Base System

    Linux Kernel: Ubuntu's linux-generic (from official repos)
    Init System: systemd
    Desktop: XFCE4 with Whisker Menu plugin
    Display Manager: LightDM (auto-login enabled for live session)
    Default User: piper / password: piper (has sudo access)

Pre-installed Software
Category 	Apps
Browser 	Firefox
File Manager 	Thunar (with archive & volume plugins)
Text Editor 	Mousepad, Gedit
Terminal 	XFCE4 Terminal
Media 	VLC, Eye of GNOME
System 	GParted, GNOME Disks, Synaptic Package Manager, htop, Neofetch
Networking 	NetworkManager, wget, curl, OpenSSH client
Appearance 	Arc Theme, Papirus Icons, Noto & Ubuntu fonts
Audio 	PulseAudio, PavuControl
Bluetooth 	Bluez, Blueman
Branding

    OS Name: Piper OS 1.0
    Codename: Rattenfänger (German for "Pied Piper")
    Custom /etc/os-release and /etc/lsb-release
    Custom login banner (/etc/issue)
    GRUB boot menu with Piper green color scheme

Project Structure

piper-os/
├── distro/                          # ← The new distro build system
│   ├── build-piper-os.sh           # Main build script (run with sudo)
│   ├── config/
│   │   ├── packages.list           # All packages to include
│   │   ├── os-release              # Custom OS identity file
│   │   └── grub/                   # GRUB theme assets (Phase 2 work)
│   └── work/                       # (generated at build time)
│       ├── chroot/                 # The full root filesystem
│       └── iso/                    # ISO staging directory
│
├── boot.s, kernel.c, gdt.c, ...   # Old bare-metal kernel (archived)
├── piper-os.iso                    # Old bare-metal kernel ISO (archived)
└── DOCUMENTATION.md                # This file

How to Build

cd /home/kratos/OS/piper-os/distro
sudo ./build-piper-os.sh

Takes ~25-35 minutes. Fully automated, no user input needed after sudo password.
How to Test

qemu-system-x86_64 -m 2G -cdrom distro/piper-os-live.iso -enable-kvm

What's Next (After First Successful Build)
Theming & Polish

    Custom XFCE4 panel layout (macOS-like dock or Windows-like taskbar)
    Custom wallpaper (Pied Piper branded)
    Plymouth boot splash animation (animated Piper logo)
    LightDM greeter theme (custom login screen)
    Custom GRUB splash screen (reuse our earlier GRUB animation work)
    GTK theme customization (dark mode, green accents)
    Custom icons for app launcher 

Installer

    Add Calamares installer (so users can install Piper OS to a real disk)
    Partitioning presets
    Post-install welcome screen

System Enhancements

    Neofetch config showing Piper OS ASCII art
    Custom .bashrc with Piper prompt
    Pre-configured VS Code or another code editor
    Firewall setup (ufw)
    Automatic updates configuration

History

This project originally started as a bare-metal x86 kernel written from scratch in C and Assembly (custom GDT, IDT, PIC, VGA driver, keyboard driver, animated boot sequence). That code remains in the repo root as a learning artifact. The project has since pivoted to building a proper Linux distribution.
