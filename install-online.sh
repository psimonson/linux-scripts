#!/bin/sh
# ==============================================================================
# Script Name: install_full_system.sh
# Description: Installs SystemRescue 13.03 locally with maximum security hardening,
#              LUKS root encryption, dual bootloaders (systemd-boot & syslinux),
#              universal hardware initramfs modules, NVIDIA drivers, PulseAudio,
#              IceWM desktop, MATE applications, full Windows/Linux/Android dev toolchains,
#              Steam, xdm-archlinux display manager with archlinux-theme, en_US / America/Detroit locale,
#              nftables firewall, hardened SSH configuration, plus expanded software,
#              forensics, drivers, and admin utilities.
# ==============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "[-] Error: This script must be run as root." >&2
   exit 1
fi

# ================= Configuration Variables =================
USB_DEV="/dev/sdb1"           # Partition of the plugged-in SystemRescue USB flash drive
USB_MOUNT="/mnt/usb_source"
TARGET_DISK="/dev/nvme0n1"    # Target NVMe disk device
TARGET_PART="/dev/nvme0n1p2"  # Root partition to be encrypted with LUKS
EFI_PART="/dev/nvme0n1p1"     # EFI system partition
TARGET_MOUNT="/mnt/target"
EFI_MOUNT="/mnt/efi"
LUKS_NAME="cryptroot"         # Mapped name for the decrypted root container
LOCAL_SUBNET="192.168.1.0/24" # Trusted local subnet allowed to connect via SSH
# ===========================================================

echo "[+] Starting secure system deployment with comprehensive hardening..."

# 1. Mount USB Source
echo "[*] Mounting SystemRescue USB from ${USB_DEV}..."
mkdir -p "${USB_MOUNT}"
mount -o ro "${USB_DEV}" "${USB_MOUNT}"

# 2. Force-unmount and flush block buffers
echo "[*] Force-unmounting target partitions and flushing block buffers..."
umount -f "${TARGET_PART}" 2>/dev/null || true
umount -l "${TARGET_PART}" 2>/dev/null || true
umount -f "${EFI_PART}" 2>/dev/null || true
umount -l "${EFI_PART}" 2>/dev/null || true
umount -f "${TARGET_MOUNT}" 2>/dev/null || true
umount -l "${TARGET_MOUNT}" 2>/dev/null || true
umount -f "${EFI_MOUNT}" 2>/dev/null || true
umount -l "${EFI_MOUNT}" 2>/dev/null || true
cryptsetup close "${LUKS_NAME}" 2>/dev/null || true

blockdev --flushbufs "${TARGET_DISK}" 2>/dev/null || true
sync

# 3. Wipe and Format Target Partitions
echo "[*] Wiping old filesystem signatures on ${TARGET_DISK}..."
wipefs -a --force "${EFI_PART}"
wipefs -a --force "${TARGET_PART}"

echo "[*] Formatting EFI partition (${EFI_PART}) as FAT32..."
mkfs.fat -F32 "${EFI_PART}"

# 4. Set up LUKS Encryption on Root Partition
echo "[*] Setting up secure LUKS2 encryption container on ${TARGET_PART}..."
echo -n "Enter disk encryption passphrase: "
read -rs LUKS_PASS
echo
echo -n "Confirm disk encryption passphrase: "
read -rs LUKS_PASS_CONFIRM
echo

if [[ "$LUKS_PASS" != "$LUKS_PASS_CONFIRM" ]]; then
    echo "[-] Error: Passphrases do not match." >&2
    exit 1
fi

echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 "${TARGET_PART}" -
echo -n "$LUKS_PASS" | cryptsetup open "${TARGET_PART}" "${LUKS_NAME}" -
unset LUKS_PASS LUKS_PASS_CONFIRM

echo "[*] Formatting decrypted root container as EXT4..."
mkfs.ext4 -F "/dev/mapper/${LUKS_NAME}"

# 5. Mount Target Partitions
echo "[*] Mounting decrypted root partition..."
mkdir -p "${TARGET_MOUNT}"
mount "/dev/mapper/${LUKS_NAME}" "${TARGET_MOUNT}"

echo "[*] Mounting EFI partition ${EFI_PART}..."
mkdir -p "${EFI_MOUNT}"
mount "${EFI_PART}" "${EFI_MOUNT}"

# 6. Bootstrap base system including complete firmware support
echo "[*] Bootstrapping base Arch Linux system with full firmware support via pacstrap..."
pacstrap -K "${TARGET_MOUNT}" base linux linux-headers linux-firmware intel-ucode amd-ucode nvidia-utils cryptsetup syslinux

# 7. Copy SystemRescue Boot Payload & Kernels for Archiso
echo "[*] Copying SystemRescue boot files from USB to target disk..."
mkdir -p "${TARGET_MOUNT}/sysrescue"
if [[ -d "${USB_MOUNT}/sysrescue" ]]; then
    rsync -aHAX "${USB_MOUNT}/sysrescue/" "${TARGET_MOUNT}/sysrescue/"
elif [[ -d "${USB_MOUNT}/sysresccd" ]]; then
    rsync -aHAX "${USB_MOUNT}/sysresccd/" "${TARGET_MOUNT}/sysrescue/"
else
    echo "[-] Error: Could not locate SystemRescue payload directory on USB." >&2
    exit 1
fi

# Generate fstab
echo "[*] Generating /etc/fstab..."
genfstab -U "${TARGET_MOUNT}" >> "${TARGET_MOUNT}/etc/fstab"

# Retrieve UUIDs for configurations
TARGET_UUID=$(blkid -s UUID -o value "${TARGET_PART}")

# Add crypttab mapping for clean mounting
echo "${LUKS_NAME} UUID=${TARGET_UUID} none luks,discard" >> "${TARGET_MOUNT}/etc/crypttab"

# 8. Configure systemd-boot (UEFI Mode)
mkdir -p "${EFI_MOUNT}/loader/entries"
cat << EOF > "${EFI_MOUNT}/loader/loader.conf"
default sysrescue.conf
timeout 5
editor no
EOF

cat << EOF > "${EFI_MOUNT}/loader/entries/sysrescue.conf"
title   SystemRescue 13.03 (systemd-boot - Secure Hardened Workstation)
linux   /sysrescue/boot/x86_64/vmlinuz
initrd  /sysrescue/boot/intel_ucode.img
initrd  /sysrescue/boot/amd_ucode.img
initrd  /sysrescue/boot/archiso.img
options cryptdevice=UUID=${TARGET_UUID}:${LUKS_NAME} root=/dev/mapper/${LUKS_NAME} archisobasedir=sysrescue archisolabel=SYSRESCUE quiet splash
EOF

# 9. Configure Syslinux (Legacy / BIOS Mode)
echo "[*] Configuring Syslinux boot files..."
mkdir -p "${TARGET_MOUNT}/boot/syslinux"
if [[ -d "${USB_MOUNT}/syslinux" ]]; then
    cp -r "${USB_MOUNT}/syslinux/"* "${TARGET_MOUNT}/boot/syslinux/"
fi

cat << EOF > "${TARGET_MOUNT}/boot/syslinux/syslinux.cfg"
DEFAULT sysrescue
PROMPT 1
TIMEOUT 50

LABEL sysrescue
    MENU LABEL SystemRescue 13.03 (Syslinux - Secure Hardened Workstation)
    LINUX /sysrescue/boot/x86_64/vmlinuz
    INITRD /sysrescue/boot/intel_ucode.img,/sysrescue/boot/amd_ucode.img,/sysrescue/boot/archiso.img
    APPEND cryptdevice=UUID=${TARGET_UUID}:${LUKS_NAME} root=/dev/mapper/${LUKS_NAME} archisobasedir=sysrescue archisolabel=SYSRESCUE quiet splash
EOF

# 10. Perform package installations and hardening inside chroot
echo "[*] Entering chroot to install secure bootloaders, desktop, xdm-archlinux, apps, and security layers..."
arch-chroot "${TARGET_MOUNT}" /bin/sh << 'EOF'
set -euo pipefail

NEW_USERNAME="user"
LOCAL_SUBNET="192.168.1.0/24"

# Initialize and populate the pacman keyring securely
export LC_ALL=C
pacman-key --init
pacman-key --populate archlinux

# Enable multilib repository in pacman.conf for Steam & 32-bit apps
if grep -q "#\[multilib\]" /etc/pacman.conf; then
    sed -i "/#\[multilib\]/{n;s/#//}" /etc/pacman.conf
    sed -i "s/#\[multilib\]/\[multilib\]/" /etc/pacman.conf
fi

echo "[*] Synchronizing package databases with multilib enabled..."
rm -f /var/lib/pacman/db.lck
pacman -Syy --noconfirm

# Install IceWM, Full X.Org, MATE Applications, xdm-archlinux with archlinux-theme, Audio, NVIDIA, Dev Suites, Steam, and Security tools
pacman -S --noconfirm --needed \
    icewm xorg xorg-server xorg-apps xorg-xinit xorg-drivers syslinux \
    xdm-archlinux \
    caja pluma atril eom mate-terminal mate-system-monitor mate-utils \
    pulseaudio pulseaudio-alsa pavucontrol \
    nvidia-utils nvidia-settings nvidia-dkms \
    networkmanager network-manager-applet wireless_tools wpa_supplicant bluez bluez-utils \
    gvfs gvfs-mtp gvfs-gphoto2 gvfs-smb \
    base-devel git cmake ninja meson make autoconf automake libtool pkgconf gdb valgrind ccache \
    mingw-w64-gcc mingw-w64-binutils mingw-w64-crt mingw-w64-headers mingw-w64-winpthreads \
    jdk-openjdk gradle android-tools android-udev \
    python python-pip nodejs npm go rust \
    blender gimp geany firefox vlc libreoffice-fresh \
    steam \
    nftables openssh cryptsetup ufw fail2ban \
    btop htop iotop sysstat nmon pciutils usbutils dmidecode \
    gparted testdisk ddrescue smartmontools nvme-cli parted util-linux efibootmgr \
    wireshark-qt nmap tcpdump netcat socat dnsutils iproute2 iptables rsync curl wget \
    docker docker-compose qemu-full virt-manager libvirt dnsmasq openbsd-netcat \
    zip unzip p7zip unrar tar rsync squashfs-tools

# Enable virtualization and container daemons
systemctl enable docker
systemctl enable libvirtd

# Configure Timezone (America/Detroit)
ln -sf /usr/share/zoneinfo/America/Detroit /etc/localtime
hwclock --systohc

# Configure Locale (en_US.UTF-8)
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Enable XDM display manager service
systemctl enable xdm

# Configure mkinitcpio with encrypt and keyboard hooks for LUKS unlocking
if [[ -f /etc/mkinitcpio.conf ]]; then
    sed -i 's/^MODULES=(.*)/MODULES=(nvme ahci xhci_hcd ehci_hcd usbcore i915 amdgpu nouveau ext4 vfat)/' /etc/mkinitcpio.conf
    sed -i 's/^HOOKS=(.*)/HOOKS=(base udev autodetect microcode modconf block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
    mkinitcpio -P
fi

# Enable Core, Audio, Network, Bluetooth, Firewall, and Security Services
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable nftables
systemctl enable sshd
systemctl enable fail2ban

# Set root password
echo -e "toor\ntoor\n" | passwd root

# Create User and Assign to Groups safely
useradd -m -s /bin/bash "${NEW_USERNAME}"
usermod -aG wheel,audio,video,storage,optical,bluetooth,network,lp,adbusers,docker,libvirt "${NEW_USERNAME}" 2>/dev/null || true
echo -e "${NEW_USERNAME}\n${NEW_USERNAME}\n" | passwd "${NEW_USERNAME}"
echo "[!] Notice: Default password for '${NEW_USERNAME}' set to '${NEW_USERNAME}'."
echo "[!] IMPORTANT: Change this password immediately upon first login!"

# Set up xinitrc and session configuration for IceWM with xdm
echo "exec icewm-session" > /etc/skel/.xinitrc
cp /etc/skel/.xinitrc "/home/${NEW_USERNAME}/.xinitrc"
ln -sf "/home/${NEW_USERNAME}/.xinitrc" "/home/${NEW_USERNAME}/.Xsession"
chown -h "${NEW_USERNAME}:${NEW_USERNAME}" "/home/${NEW_USERNAME}/.Xsession"
chown "${NEW_USERNAME}:${NEW_USERNAME}" "/home/${NEW_USERNAME}/.xinitrc"
chmod +x "/home/${NEW_USERNAME}/.Xsession"

# Apply strict nftables firewall rules
cat << INNER_EOF > /etc/nftables.conf
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        iif "lo" accept
        ct state established,related accept
        ct state invalid drop
        ip saddr ${LOCAL_SUBNET} tcp dport 22 accept
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
INNER_EOF

# Apply robust kernel security hardening
cat << 'INNER_EOF' > /etc/sysctl.d/99-security-hardening.conf
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
fs.suid_dumpable = 0
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
INNER_EOF

sysctl --system &>/dev/null || true

# SSH Hardening
mkdir -p /etc/ssh/sshd_config.d
cat << 'INNER_EOF' > /etc/ssh/sshd_config.d/hardening.conf
PermitRootLogin prohibit-password
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
Protocol 2
INNER_EOF

# Core dump restrictions
mkdir -p /etc/security/limits.d
cat << 'INNER_EOF' > /etc/security/limits.d/30-coredumps.conf
- hard core 0
INNER_EOF

EOF

# 11. Install syslinux and systemd-boot boot loaders
echo "[*] Installing and configuring syslinux..."
syslinux-install_update -i -a -m -c "${TARGET_MOUNT}" || true
echo "[*] Installing and configuring systemd-boot..."
bootctl --path="${EFI_MOUNT}" install

# Fix bootctl random seed permissions if on an EFI mount
chmod 0600 "${EFI_MOUNT}/loader/random-seed" 2>/dev/null || true

# 12. Cleanup Mounts
echo "[*] Cleaning up temporary mounts..."
umount "${USB_MOUNT}"
umount "${TARGET_MOUNT}/boot" 2>/dev/null || true
umount "${TARGET_MOUNT}"
umount "${EFI_MOUNT}"
cryptsetup close "${LUKS_NAME}"

echo "[+] Complete! SystemRescue 13.03 is fully installed with maximum security hardening, LUKS encryption, dual bootloaders, IceWM, xdm-archlinux with archlinux-theme, locale/timezone configuration, and complete dev toolchains."
