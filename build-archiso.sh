#!/bin/sh
set -euo pipefail

### ==============================================================================
### Copyright (C) 2026, Philip R. Simonson. All rights reserved.
### Arch Linux Custom Live ISO & Offline Installer Builder
### Uses syslinux (BIOS/MBR) + systemd-boot (UEFI) instead of GRUB
### ==============================================================================

WORK_DIR="/var/tmp/archiso_work"
OUT_DIR="${OUT_DIR:-$(pwd)/out}"
PROFILE_DIR="/var/tmp/archiso_profile"
BUILD_USER="aurbuilder"

if [ "$(id -u)" -ne 0 ]; then
    printf 'Error: Must be run as root.\n' >&2
    exit 1
fi

cleanup_host() {
    userdel -r "$BUILD_USER" 2>/dev/null || true
    rm -f "/etc/sudoers.d/$BUILD_USER"
}
trap cleanup_host EXIT

printf '==> Installing host build dependencies...\n'
pacman -Sy --needed --noconfirm \
    archiso mkinitcpio-archiso base-devel git squashfs-tools libisoburn dosfstools gptfdisk

### Ensure multilib is enabled on host for 32-bit Steam/Wine libs
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
    pacman -Sy --noconfirm
fi

printf '==> Cleaning previous build directories...\n'
rm -rf "$WORK_DIR" "$PROFILE_DIR"
mkdir -p "$OUT_DIR"

cp -r /usr/share/archiso/configs/releng "$PROFILE_DIR"
AIROOTFS="$PROFILE_DIR/airootfs"
LOCAL_REPO_DIR="$AIROOTFS/var/cache/custom_offline"

mkdir -p "$AIROOTFS/etc" "$AIROOTFS/root" "$AIROOTFS/etc/skel" "$LOCAL_REPO_DIR"

### Enable multilib in the ISO's pacman.conf
if ! grep -q "^\[multilib\]" "$PROFILE_DIR/pacman.conf"; then
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> "$PROFILE_DIR/pacman.conf"
fi

### ==============================================================================
### 1. Build AUR & Custom Source Packages into airootfs
### ==============================================================================
printf '==> Setting up AUR builder user...\n'
if ! id "$BUILD_USER" >/dev/null 2>&1; then
    groupadd -f "$BUILD_USER"
    useradd -m -g "$BUILD_USER" -G wheel -s /bin/bash "$BUILD_USER"
fi
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$BUILD_USER" > "/etc/sudoers.d/$BUILD_USER"
chmod 440 "/etc/sudoers.d/$BUILD_USER"

build_pkg() {
    local package="$1"
    local account="${2:-}"
    local branch="${3:-}"

    if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
        printf 'Wrong number of arguments to build_pkg.\n' >&2
        return 1
    fi

    printf '==> Building custom source package: %s...\n' "$package"
    rm -rf "/tmp/$package"

    if [ -n "$branch" ] && git clone --depth 1 "https://github.com/$account/$package.git" -b "$branch" "/tmp/$package" 2>/dev/null; then
        :
    elif git clone --depth 1 "https://github.com/$account/$package.git" "/tmp/$package" 2>/dev/null; then
        :
    else
        printf 'Error: Failed to clone repo %s/%s.\n' "$account" "$package" >&2
        return 1
    fi

    pushd "/tmp/$package" >/dev/null
    local build_file
    build_file=$(find . -maxdepth 2 -type f \( -name 'Makefile' -o -name 'CMakeLists.txt' \) | head -n 1)

    if [ -z "$build_file" ]; then
        printf 'Error: No Makefile or CMakeLists.txt found in %s.\n' "$package" >&2
        popd >/dev/null
        rm -rf "/tmp/$package"
        return 1
    fi

    case "$(basename "$build_file")" in
        Makefile)
            make clean all
            make DESTDIR="$AIROOTFS" PREFIX=/usr install
            ;;
        CMakeLists.txt)
            cmake -S . -B build -G 'Unix Makefiles' -DCMAKE_INSTALL_PREFIX=/usr
            cmake --build build --target all
            DESTDIR="$AIROOTFS" cmake --install build
            ;;
    esac
    popd >/dev/null
    rm -rf "/tmp/$package"
}

build_aur() {
    local package="$1"
    [ "$#" -eq 1 ] || return 1

    printf '==> Building AUR package: %s...\n' "$package"
    su - "$BUILD_USER" -c "
        set -euo pipefail
        rm -rf '/tmp/$package'
        git clone --depth 1 'https://aur.archlinux.org/$package.git' '/tmp/$package'
        cd '/tmp/$package'
        makepkg -f -s --noconfirm --needed
    "
    cp "/tmp/$package/"*.pkg.tar.zst "$LOCAL_REPO_DIR/"
    rm -rf "/tmp/$package"
}

build_aur "google-chrome"
build_aur "clion"
# build_aur "heroic-games-launcher-bin"
build_pkg "stackwm" "psimonson"

### Generate offline repository database and register it in profile pacman.conf
if compgen -G "$LOCAL_REPO_DIR/*.pkg.tar.zst" > /dev/null; then
    repo-add "$LOCAL_REPO_DIR/custom_offline.db.tar.gz" "$LOCAL_REPO_DIR/"*.pkg.tar.zst
    cat <<EOF >> "$PROFILE_DIR/pacman.conf"

[custom_offline]
SigLevel = Optional TrustAll
Server = file://$LOCAL_REPO_DIR
EOF
fi

### ==============================================================================
### 2. Populate packages.x86_64
### ==============================================================================
printf '==> Configuring package list...\n'
cat <<'EOF' >> "$PROFILE_DIR/packages.x86_64"

### --- Custom Offline AUR Packages ---
google-chrome
clion

### --- Base System, Kernel, Firmware & Core Tools ---
base
linux
linux-headers
linux-firmware
base-devel
sudo
vim
nano
git
wget
curl
rsync
unzip
zip
p7zip
htop
btop
tmux
openssh
cryptsetup
lvm2
btrfs-progs
dosfstools
ntfs-3g
exfatprogs
parted
gptfdisk
efibootmgr
syslinux
mtools

### --- Networking, Bluetooth, Audio & Logging ---
networkmanager
network-manager-applet
net-tools
iw
nftables
bluez
bluez-utils
blueman
pulseaudio
pulseaudio-alsa
pulseaudio-bluetooth
pavucontrol
alsa-utils
syslog-ng
audit

### --- Xorg & Standard GTK Desktop Utilities (No Full DE) ---
xorg-server
xorg-xinit
xorg-xrandr
xorg-xsetroot
xorg-xrdb
xorg-xcalc
xclip
xdm-archlinux
mesa
vulkan-icd-loader
lib32-vulkan-icd-loader
gvfs
gvfs-mtp
gvfs-smb
thunar
thunar-archive-plugin
file-roller
mousepad
geany
geany-plugins
ristretto
evince
gnome-disk-utility
gnome-keyring
seahorse
lxappearance
xfce4-terminal
ttf-dejavu
ttf-liberation
noto-fonts
noto-fonts-emoji
papirus-icon-theme

### --- Graphics & Virtualization (NVIDIA, AMD, VirtualBox) ---
nvidia-dkms
nvidia-utils
lib32-nvidia-utils
nvidia-settings
xf86-video-amdgpu
vulkan-radeon
lib32-vulkan-radeon
virtualbox
virtualbox-host-dkms
virtualbox-guest-iso

### --- Development: Linux, Windows (MinGW), Android, Debugging ---
gcc
clang
llvm
lld
cmake
ninja
meson
make
autoconf
automake
pkgconf
gdb
lldb
valgrind
strace
ltrace
mingw-w64
wine
wine-mono
wine-gecko
winetricks
jdk-openjdk
android-tools
android-udev
python
python-pip
rust
go

### --- Creative & Gaming (GIMP, Blender, Steam, Lutris/Epic/Battle.net/Ubisoft) ---
gimp
blender
steam
lutris
lib32-gnutls
lib32-libldap
lib32-libgpg-error
lib32-sqlite
lib32-libpulse
lib32-alsa-plugins
gamemode
lib32-gamemode
EOF

### Deduplicate packages.x86_64 while preserving comments and blank lines
awk '!NF || /^#/ || !seen[$0]++' "$PROFILE_DIR/packages.x86_64" > "$PROFILE_DIR/packages.x86_64.tmp"
mv "$PROFILE_DIR/packages.x86_64.tmp" "$PROFILE_DIR/packages.x86_64"

### ==============================================================================
### 3. Configure Live Rootfs & System Defaults
### ==============================================================================
ln -sf /usr/share/zoneinfo/America/Detroit "$AIROOTFS/etc/localtime"
printf 'en_US.UTF-8 UTF-8\n' > "$AIROOTFS/etc/locale.gen"
printf 'LANG=en_US.UTF-8\n' > "$AIROOTFS/etc/locale.conf"
printf 'KEYMAP=us\n' > "$AIROOTFS/etc/vconsole.conf"
printf 'archlive\n' > "$AIROOTFS/etc/hostname"

mkdir -p "$AIROOTFS/etc/sudoers.d"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$AIROOTFS/etc/sudoers.d/10-wheel"
chmod 440 "$AIROOTFS/etc/sudoers.d/10-wheel"

mkdir -p "$AIROOTFS/etc/modprobe.d"
printf 'blacklist nouveau\n' > "$AIROOTFS/etc/modprobe.d/nouveau.conf"

### Default skeleton Xsession files for all new users
cat <<'XINIT_EOF' > "$AIROOTFS/etc/skel/.xinitrc"
#!/bin/sh
exec stackwm
XINIT_EOF
chmod 755 "$AIROOTFS/etc/skel/.xinitrc"
ln -sf .xinitrc "$AIROOTFS/etc/skel/.xsession"

### Remove releng tty1 autologin override so XDM owns graphical login cleanly
rm -rf "$AIROOTFS/etc/systemd/system/getty@tty1.service.d"

### Ensure profiledef.sh enforces strict permissions on sudoers and scripts
if grep -q 'file_permissions=(' "$PROFILE_DIR/profiledef.sh"; then
    sed -i '/file_permissions=(/a \  ["/etc/sudoers.d/10-wheel"]="0:0:0440"\n  ["/root/install.sh"]="0:0:0755"\n  ["/root/customize_airootfs.sh"]="0:0:0755"' "$PROFILE_DIR/profiledef.sh"
fi

### Native mkarchiso chroot customization script (runs during ISO build!)
cat <<EOF > "$AIROOTFS/root/customize_airootfs.sh"
#!/bin/sh
set -euo pipefail

### Point custom_offline repo to the in-target path inside the live/installed system
if grep -q "file://$LOCAL_REPO_DIR" /etc/pacman.conf; then
    sed -i 's|file://$LOCAL_REPO_DIR|file:///var/cache/custom_offline|g' /etc/pacman.conf
fi

locale-gen

### Set root password to 'toor'
printf 'root:toor\n' | chpasswd

### Create 'user' with password 'user'
if ! id user >/dev/null 2>&1; then
    useradd -m -s /bin/bash user
fi
printf 'user:user\n' | chpasswd

### Add 'user' to standard non-root user groups
USER_GROUPS="wheel,audio,video,optical,storage,disk,input,kvm,render,lp,scanner,uucp,games,users,vboxusers,adbusers"
for grp in \$(printf '%s' "\$USER_GROUPS" | tr ',' ' '); do
    groupadd -f "\$grp"
    usermod -aG "\$grp" user
done

### Ensure /home/user/.xinitrc and /home/user/.xsession exist and are owned by user
cp /etc/skel/.xinitrc /home/user/.xinitrc
ln -sf /home/user/.xinitrc /home/user/.xsession
chown -R user:user /home/user
chmod 755 /home/user/.xinitrc

### Enable core services in the live image
systemctl enable NetworkManager.service
systemctl enable bluetooth.service
systemctl enable syslog-ng@default.service
systemctl enable auditd.service
systemctl enable polkit.service
systemctl enable xdm-archlinux.service
systemctl enable vboxservice.service 2>/dev/null || true
EOF
chmod 755 "$AIROOTFS/root/customize_airootfs.sh"

### ==============================================================================
### 4. Embed Offline Installer Script (/root/install.sh)
### ==============================================================================
cat <<'INSTALL_EOF' > "$AIROOTFS/root/install.sh"
#!/bin/sh
set -euo pipefail

### ==============================================================================
### Copyright (C) 2026, Philip R. Simonson. All rights reserved.
### Offline Arch Linux Bare-Metal Installer
### Clones the running live environment, configures LUKS/partitions, installs
### systemd-boot + syslinux + auto-update pacman hook, hardens the OS, sets up
### automounting for /boot & /efi, updates credentials, and unmounts cleanly.
### ==============================================================================

TARGET_MNT="/mnt"
CRYPT_NAME="cryptroot"

if [ "$(id -u)" -ne 0 ]; then
    printf 'Error: install.sh must be run as root.\n' >&2
    exit 1
fi

### ------------------------------------------------------------------------------
### Cleanup / Unmount Function (Used at start and at exit)
### ------------------------------------------------------------------------------
cleanup_mounts() {
    printf '==> Unmounting any active target filesystems and closing LUKS...\n'
    swapoff -a 2>/dev/null || true

    if mountpoint -q "$TARGET_MNT/efi" 2>/dev/null; then
        umount -R "$TARGET_MNT/efi" 2>/dev/null || umount -l "$TARGET_MNT/efi" 2>/dev/null || true
    fi
    if mountpoint -q "$TARGET_MNT/boot" 2>/dev/null; then
        umount -R "$TARGET_MNT/boot" 2>/dev/null || umount -l "$TARGET_MNT/boot" 2>/dev/null || true
    fi
    if mountpoint -q "$TARGET_MNT" 2>/dev/null; then
        umount -R "$TARGET_MNT" 2>/dev/null || umount -l "$TARGET_MNT" 2>/dev/null || true
    fi

    udevadm settle 2>/dev/null || true

    if [ -e "/dev/mapper/$CRYPT_NAME" ]; then
        cryptsetup close "$CRYPT_NAME" 2>/dev/null || true
    fi
    for dm in /dev/mapper/*; do
        [ -e "$dm" ] || continue
        base=$(basename "$dm")
        if [ "$base" != "control" ] && cryptsetup status "$base" >/dev/null 2>&1; then
            cryptsetup close "$base" 2>/dev/null || true
        fi
    done
}

cleanup_mounts

### ------------------------------------------------------------------------------
### Disk Selection & Partitioning
### ------------------------------------------------------------------------------
printf '\nAvailable block devices:\n'
lsblk -d -p -n -o NAME,SIZE,MODEL,TYPE | grep "disk" || true
printf '\nEnter target disk device (e.g., /dev/nvme0n1 or /dev/sda): '
read -r TARGET_DISK

if [ ! -b "$TARGET_DISK" ]; then
    printf 'Error: %s is not a valid block device.\n' "$TARGET_DISK" >&2
    exit 1
fi

printf 'WARNING: All data on %s will be destroyed! Type '\''YES'\'' to continue: ' "$TARGET_DISK"
read -r CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    printf 'Aborted.\n'
    exit 1
fi

printf 'Encrypt root partition with LUKS2? (y/n): '
read -r USE_LUKS

case "$TARGET_DISK" in
    *nvme*|*mmcblk*|*loop*) PART_PREFIX="${TARGET_DISK}p" ;;
    *) PART_PREFIX="${TARGET_DISK}" ;;
esac

# Partition 1: 1M BIOS Boot (ef02)
# Partition 2: 512M EFI (ef00)
# Partition 3: 1024M /boot (ea00) - Legacy BIOS bootable attribute set
# Partition 4: Remainder / (8309)
BIOS_PART="${PART_PREFIX}1"
EFI_PART="${PART_PREFIX}2"
BOOT_PART="${PART_PREFIX}3"
ROOT_PART="${PART_PREFIX}4"

printf '==> Partitioning %s (GPT: 1M BIOS, 512M /efi, 1G /boot, remainder /)...\n' "$TARGET_DISK"
wipefs -af "$TARGET_DISK"
sgdisk --zap-all "$TARGET_DISK"
sgdisk -n 1:0:+1M    -t 1:ef02 -c 1:"BIOS" "$TARGET_DISK"
sgdisk -n 2:0:+512M  -t 2:ef00 -c 2:"EFI"  "$TARGET_DISK"
sgdisk -n 3:0:+1024M -t 3:ea00 -c 3:"BOOT" "$TARGET_DISK"
sgdisk -n 4:0:0      -t 4:8309 -c 4:"ROOT" "$TARGET_DISK"
sgdisk --attributes=3:set:2 "$TARGET_DISK"
partprobe "$TARGET_DISK"
udevadm settle 2>/dev/null || sleep 2

printf '==> Formatting /efi and /boot...\n'
mkfs.fat -F32 -n EFI "$EFI_PART"
mkfs.ext4 -F -L BOOT "$BOOT_PART"

if [ "$USE_LUKS" = "y" ] || [ "$USE_LUKS" = "Y" ]; then
    printf '==> Setting up LUKS2 encryption on %s...\n' "$ROOT_PART"
    cryptsetup luksFormat --type luks2 --pbkdf argon2id "$ROOT_PART"
    printf '==> Opening LUKS container...\n'
    cryptsetup open "$ROOT_PART" "$CRYPT_NAME"
    ROOT_DEV="/dev/mapper/$CRYPT_NAME"
else
    ROOT_DEV="$ROOT_PART"
fi

printf '==> Formatting root filesystem (ext4)...\n'
mkfs.ext4 -F -L ARCHROOT "$ROOT_DEV"

printf '==> Mounting target filesystems...\n'
mount "$ROOT_DEV" "$TARGET_MNT"
mkdir -p "$TARGET_MNT/boot" "$TARGET_MNT/efi"
mount "$BOOT_PART" "$TARGET_MNT/boot"
mount "$EFI_PART" "$TARGET_MNT/efi"

### ------------------------------------------------------------------------------
### Offline System Copy
### ------------------------------------------------------------------------------
printf '==> Copying offline system image to %s...\n' "$TARGET_MNT"
rsync -aAX --info=progress2 \
    --exclude="/dev/*" \
    --exclude="/proc/*" \
    --exclude="/sys/*" \
    --exclude="/tmp/*" \
    --exclude="/run/*" \
    --exclude="/mnt/*" \
    --exclude="/media/*" \
    --exclude="/lost+found" \
    --exclude="/etc/mkinitcpio.conf.d/archiso.conf" \
    --exclude="/etc/mkinitcpio.d/linux.preset" \
    / "$TARGET_MNT/"

mkdir -p "$TARGET_MNT/dev" "$TARGET_MNT/proc" "$TARGET_MNT/sys" "$TARGET_MNT/tmp" "$TARGET_MNT/run" "$TARGET_MNT/mnt"
chmod 1777 "$TARGET_MNT/tmp"

BOOT_SRC="/run/archiso/bootmnt/arch/boot/x86_64"
if [ -f "$BOOT_SRC/vmlinuz-linux" ]; then
    cp "$BOOT_SRC/vmlinuz-linux" "$TARGET_MNT/boot/vmlinuz-linux"
fi

mkdir -p "$TARGET_MNT/etc/mkinitcpio.d"
cat <<'PRESET_EOF' > "$TARGET_MNT/etc/mkinitcpio.d/linux.preset"
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"

PRESETS=('default' 'fallback')

default_image="/boot/initramfs-linux.img"
fallback_image="/boot/initramfs-linux-fallback.img"
fallback_options="-S autodetect"
PRESET_EOF

rm -f "$TARGET_MNT/root/install.sh" "$TARGET_MNT/root/customize_airootfs.sh"

### ------------------------------------------------------------------------------
### Generate fstab with Systemd Automount for /boot and /efi
### ------------------------------------------------------------------------------
printf '==> Generating fstab with on-demand automounting for /boot and /efi...\n'
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")

cat <<FSTAB_EOF > "$TARGET_MNT/etc/fstab"
### <file system> <dir> <type> <options> <dump> <pass>
UUID=$ROOT_UUID /     ext4  rw,relatime,errors=remount-ro 0 1
UUID=$BOOT_UUID /boot ext4  rw,relatime,noauto,x-systemd.automount,x-systemd.idle-timeout=10 0 2
UUID=$EFI_UUID  /efi  vfat  rw,relatime,fmask=0077,dmask=0077,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro,noauto,x-systemd.automount,x-systemd.idle-timeout=10 0 2
FSTAB_EOF

### ------------------------------------------------------------------------------
### Configure Bootloaders (systemd-boot + syslinux), Hook & Hardening
### ------------------------------------------------------------------------------
printf '==> Configuring modules, hooks, initramfs, bootloaders, and hardening...\n'

sed -i 's/^MODULES=.*/MODULES=(btrfs ext4 vfat)/' "$TARGET_MNT/etc/mkinitcpio.conf"

if [ "$USE_LUKS" = "y" ] || [ "$USE_LUKS" = "Y" ]; then
    RAW_ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' "$TARGET_MNT/etc/mkinitcpio.conf"
    KERNEL_OPTS="cryptdevice=UUID=${RAW_ROOT_UUID}:${CRYPT_NAME} root=/dev/mapper/${CRYPT_NAME} rw loglevel=3 quiet nvidia_drm.modeset=1"
else
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)/' "$TARGET_MNT/etc/mkinitcpio.conf"
    KERNEL_OPTS="root=UUID=${ROOT_UUID} rw loglevel=3 quiet nvidia_drm.modeset=1"
fi

### systemd-boot configuration (EFI partition is mounted at /efi, /boot is separate XBOOTLDR)
mkdir -p "$TARGET_MNT/boot/loader/entries" "$TARGET_MNT/efi/loader"
cat <<'LOADER_EOF' > "$TARGET_MNT/efi/loader/loader.conf"
default arch.conf
timeout 3
console-mode max
editor no
LOADER_EOF

cat <<ENTRY_EOF > "$TARGET_MNT/boot/loader/entries/arch.conf"
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options ${KERNEL_OPTS}
ENTRY_EOF

cat <<FALLBACK_EOF > "$TARGET_MNT/boot/loader/entries/arch-fallback.conf"
title   Arch Linux (fallback initramfs)
linux   /vmlinuz-linux
initrd  /initramfs-linux-fallback.img
options ${KERNEL_OPTS}
FALLBACK_EOF

### syslinux configuration (Paths are relative to /boot partition root!)
mkdir -p "$TARGET_MNT/boot/syslinux"
cp /usr/lib/syslinux/bios/*.c32 "$TARGET_MNT/boot/syslinux/"
cat <<SYSLINUX_EOF > "$TARGET_MNT/boot/syslinux/syslinux.cfg"
DEFAULT arch
PROMPT 0
TIMEOUT 30

LABEL arch
    MENU LABEL Arch Linux
    LINUX /vmlinuz-linux
    INITRD /initramfs-linux.img
    APPEND ${KERNEL_OPTS}

LABEL archfallback
    MENU LABEL Arch Linux (fallback initramfs)
    LINUX /vmlinuz-linux
    INITRD /initramfs-linux-fallback.img
    APPEND ${KERNEL_OPTS}
SYSLINUX_EOF

### Pacman hook to auto-update systemd-boot and syslinux on upgrades
mkdir -p "$TARGET_MNT/etc/pacman.d/hooks"
cat <<'HOOK_EOF' > "$TARGET_MNT/etc/pacman.d/hooks/99-bootloader-update.hook"
[Trigger]
Type = Package
Operation = Upgrade
Operation = Install
Target = linux
Target = systemd
Target = syslinux

[Action]
Description = Updating systemd-boot and syslinux bootloaders...
When = PostTransaction
Exec = /bin/sh -c 'if [ -d /sys/firmware/efi/efivars ]; then bootctl --esp-path=/efi --boot-path=/boot update || true; else bootctl --esp-path=/efi --boot-path=/boot --no-variables update || true; fi; syslinux-install_update -i -a -m || true'
HOOK_EOF

### Kernel & Network Security Hardening (sysctl)
cat <<'SYSCTL_EOF' > "$TARGET_MNT/etc/sysctl.d/99-hardening.conf"
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.printk = 3 3 3 3
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.yama.ptrace_scope = 1
kernel.kexec_load_disabled = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
SYSCTL_EOF

### Strict Default-Drop nftables Firewall
cat <<'NFT_EOF' > "$TARGET_MNT/etc/nftables.conf"
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        iif "lo" accept
        ct state established,related accept
        ct state invalid drop
        ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded } accept
        ip6 nexthdr icmpv6 icmpv6 type { echo-request, destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
NFT_EOF

### SSH Hardening
mkdir -p "$TARGET_MNT/etc/ssh/sshd_config.d"
cat <<'SSH_EOF' > "$TARGET_MNT/etc/ssh/sshd_config.d/99-hardening.conf"
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
SSH_EOF

### Create /home/user/.xinitrc and /home/user/.xsession before chroot
mkdir -p "$TARGET_MNT/home/user"
cat <<'XINIT_EOF' > "$TARGET_MNT/home/user/.xinitrc"
#!/bin/sh
exec stackwm
XINIT_EOF

arch-chroot "$TARGET_MNT" /bin/sh -c '
    set -euo pipefail
    ln -sf /usr/share/zoneinfo/America/Detroit /etc/localtime
    hwclock --systohc
    locale-gen
    mkinitcpio -P

    if [ -d /sys/firmware/efi/efivars ]; then
        bootctl --esp-path=/efi --boot-path=/boot install || true
    else
        bootctl --esp-path=/efi --boot-path=/boot --no-variables install || true
    fi
    syslinux-install_update -i -a -m

    systemctl enable NetworkManager.service
    systemctl enable bluetooth.service
    systemctl enable nftables.service
    systemctl enable syslog-ng@default.service
    systemctl enable xdm-archlinux.service
    systemctl enable polkit.service
    systemctl enable rtkit.service
    systemctl enable auditd.service
    systemctl enable systemd-timesyncd.service
    systemctl enable fstrim.timer

    chown -R user:user /home/user
    chmod 755 /home/user/.xinitrc
    ln -sf /home/user/.xinitrc /home/user/.xsession
    chown -h user:user /home/user/.xsession
'

### ------------------------------------------------------------------------------
### Interactive Credential & Username Reconfiguration
### ------------------------------------------------------------------------------
printf '\n==================================================================\n'
printf 'Installation complete! Configure your permanent credentials:\n'
printf '==================================================================\n'

printf 'Enter new root password: '
stty -echo
read -r NEW_ROOT_PASS
stty echo
printf '\nConfirm new root password: '
stty -echo
read -r NEW_ROOT_PASS_CONFIRM
stty echo
printf '\n'

if [ "$NEW_ROOT_PASS" != "$NEW_ROOT_PASS_CONFIRM" ] || [ -z "$NEW_ROOT_PASS" ]; then
    printf 'Error: Root passwords did not match or were empty. Keeping default '\''toor'\''.\n'
else
    printf 'root:%s\n' "$NEW_ROOT_PASS" | arch-chroot "$TARGET_MNT" chpasswd
    printf 'Root password updated.\n'
fi

printf '\nEnter new username to replace '\''user'\'': '
read -r NEW_USER

if [ -n "$NEW_USER" ] && [ "$NEW_USER" != "user" ]; then
    arch-chroot "$TARGET_MNT" usermod -l "$NEW_USER" -d "/home/$NEW_USER" -m user
    arch-chroot "$TARGET_MNT" groupmod -n "$NEW_USER" user 2>/dev/null || true
    arch-chroot "$TARGET_MNT" ln -sf "/home/$NEW_USER/.xinitrc" "/home/$NEW_USER/.xsession"
    arch-chroot "$TARGET_MNT" chown -h "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.xsession"
    TARGET_USER="$NEW_USER"
    printf 'Username changed to '\''%s'\''.\n' "$TARGET_USER"
else
    TARGET_USER="user"
    printf 'Keeping username '\''user'\''.\n'
fi

printf 'Enter new password for '\''%s'\'': ' "$TARGET_USER"
stty -echo
read -r NEW_USER_PASS
stty echo
printf '\nConfirm new password for '\''%s'\'': ' "$TARGET_USER"
stty -echo
read -r NEW_USER_PASS_CONFIRM
stty echo
printf '\n'

if [ "$NEW_USER_PASS" != "$NEW_USER_PASS_CONFIRM" ] || [ -z "$NEW_USER_PASS" ]; then
    printf 'Error: User passwords did not match or were empty. Keeping default '\''user'\''.\n'
else
    printf '%s:%s\n' "$TARGET_USER" "$NEW_USER_PASS" | arch-chroot "$TARGET_MNT" chpasswd
    printf 'Password updated for '\''%s'\''.\n' "$TARGET_USER"
fi

### ------------------------------------------------------------------------------
### Final Unmount & LUKS Close
### ------------------------------------------------------------------------------
cleanup_mounts
printf '\n==> All filesystems unmounted and LUKS containers closed. Safe to reboot!\n'
INSTALL_EOF
chmod 755 "$AIROOTFS/root/install.sh"

### ==============================================================================
### 5. Build the ISO
### ==============================================================================
printf '==> Building custom Arch Linux ISO...\n'
mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DIR"

printf '==> Cleaning up temporary build files...\n'
rm -rf "$WORK_DIR" "$PROFILE_DIR"

printf '==> Done! ISO generated in: %s\n' "$OUT_DIR"
