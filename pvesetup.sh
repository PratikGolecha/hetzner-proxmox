#!/usr/bin/bash
set -e
cd /root

# Define colors for output
CLR_RED="\033[1;31m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"
CLR_RESET="\033[m"

clear

# Ensure the script is run as root
if [[ $EUID != 0 ]]; then
    echo -e "${CLR_RED}Please run this script as root.${CLR_RESET}"
    exit 1
fi

echo -e "${CLR_GREEN}Starting Proxmox auto-installation...${CLR_RESET}"

# Function to get system information
get_system_info() {
    INTERFACE_NAME=$(udevadm info -e | grep -m1 -A 20 ^P.*eth0 | grep ID_NET_NAME_PATH | cut -d'=' -f2)
    MAIN_IPV4_CIDR=$(ip address show "$INTERFACE_NAME" | grep global | grep "inet " | xargs | cut -d" " -f2)
    MAIN_IPV4=$(echo "$MAIN_IPV4_CIDR" | cut -d'/' -f1)
    MAIN_IPV4_GW=$(ip route | grep default | xargs | cut -d" " -f3)
    MAC_ADDRESS=$(ip link show "$INTERFACE_NAME" | awk '/ether/ {print $2}')
    IPV6_CIDR=$(ip address show "$INTERFACE_NAME" | grep global | grep "inet6 " | xargs | cut -d" " -f2)
    MAIN_IPV6=$(echo "$IPV6_CIDR" | cut -d'/' -f1)

    FIRST_IPV6_CIDR="$(echo "$IPV6_CIDR" | cut -d'/' -f1 | cut -d':' -f1-4):1::1/80"

    echo -e "${CLR_YELLOW}Detected System Information:${CLR_RESET}"
    echo "Interface Name: $INTERFACE_NAME"
    echo "Main IPv4 CIDR: $MAIN_IPV4_CIDR"
    echo "Main IPv4: $MAIN_IPV4"
    echo "Main IPv4 Gateway: $MAIN_IPV4_GW"
    echo "MAC Address: $MAC_ADDRESS"
    echo "IPv6 CIDR: $IPV6_CIDR"
    echo "IPv6: $MAIN_IPV6"
    echo "First IPv6: $FIRST_IPV6_CIDR"
}

# Function to get user input
get_user_input() {
    read -e -p "Enter your hostname : " -i "proxmox-example" HOSTNAME
    read -e -p "Enter your FQDN name : " -i "proxmox.example.com" FQDN
    read -e -p "Enter your timezone : " -i "Europe/Istanbul" TIMEZONE
    read -e -p "Enter your email address: " -i "admin@example.com" EMAIL
    read -e -p "Enter your private subnet : " -i "192.168.26.0/24" PRIVATE_SUBNET
    read -e -p "Enter your System New root password: " NEW_ROOT_PASSWORD

    PRIVATE_CIDR=$(echo "$PRIVATE_SUBNET" | cut -d'/' -f1 | rev | cut -d'.' -f2- | rev)
    PRIVATE_IP="${PRIVATE_CIDR}.1"
    SUBNET_MASK=$(echo "$PRIVATE_SUBNET" | cut -d'/' -f2)
    PRIVATE_IP_CIDR="${PRIVATE_IP}/${SUBNET_MASK}"

    while [[ -z "$NEW_ROOT_PASSWORD" ]]; do
        echo ""
        read -e -p "Enter your System New root password: " NEW_ROOT_PASSWORD
    done

    echo ""
    echo "Private subnet: $PRIVATE_SUBNET"
    echo "First IP in subnet (CIDR): $PRIVATE_IP_CIDR"
}

prepare_packages() {
    echo -e "${CLR_BLUE}Installing packages...${CLR_RESET}"
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" | tee /etc/apt/sources.list.d/pve.list
    curl -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg
    apt clean && apt update && apt install -yq proxmox-auto-install-assistant xorriso ovmf wget sshpass
    echo -e "${CLR_GREEN}Packages installed.${CLR_RESET}"
}

download_proxmox_iso() {
    echo -e "${CLR_BLUE}Downloading Proxmox ISO...${CLR_RESET}"
    wget -O pve.iso https://enterprise.proxmox.com/iso/proxmox-ve_8.4-1.iso
    echo -e "${CLR_GREEN}Proxmox ISO downloaded.${CLR_RESET}"
}

make_answer_toml() {
    echo -e "${CLR_BLUE}Making answer.toml...${CLR_RESET}"
    cat <<EOF > answer.toml
[global]
    keyboard = "en-us"
    country = "us"
    fqdn = "$FQDN"
    mailto = "$EMAIL"
    timezone = "$TIMEZONE"
    root_password = "$NEW_ROOT_PASSWORD"
    reboot_on_error = false

[network]
    source = "from-dhcp"

[disk-setup]
    target_disk = "/dev/nvme0n1"
    filesystem = "zfs"
    zfs.root = "rpool"
    zfs.pool_options = "ashift=12"
    zfs.force_import = true
EOF
    echo -e "${CLR_GREEN}answer.toml created.${CLR_RESET}"
}

make_autoinstall_iso() {
    echo -e "${CLR_BLUE}Making autoinstall.iso...${CLR_RESET}"
    proxmox-auto-install-assistant prepare-iso pve.iso --fetch-from iso --answer-file answer.toml --output pve-autoinstall.iso
    echo -e "${CLR_GREEN}pve-autoinstall.iso created.${CLR_RESET}"
}

install_proxmox() {
    echo -e "${CLR_GREEN}Starting Proxmox VE installation...${CLR_RESET}"
    qemu-system-x86_64 -enable-kvm -bios /usr/share/ovmf/OVMF.fd \
      -cpu host -smp 4 -m 4096 \
      -boot d -cdrom ./pve-autoinstall.iso \
      -drive file=/dev/nvme0n1,format=raw,media=disk,if=virtio \
      -vnc :0,password=off -monitor stdio -no-reboot
}

boot_proxmox_with_port_forwarding() {
    nohup qemu-system-x86_64 -enable-kvm -bios /usr/share/ovmf/OVMF.fd \
      -cpu host -device e1000,netdev=net0 \
      -netdev user,id=net0,hostfwd=tcp::5555-:22 \
      -smp 4 -m 4096 \
      -drive file=/dev/nvme0n1,format=raw,media=disk,if=virtio \
      > qemu_output.log 2>&1 &

    QEMU_PID=$!
    for i in {1..60}; do
        if nc -z localhost 5555; then
            echo "SSH is available on port 5555."
            break
        fi
        sleep 5
    done
}

configure_proxmox_via_ssh() {
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "\
      echo 'auto lo' > /etc/network/interfaces && \
      echo 'iface lo inet loopback' >> /etc/network/interfaces && \
      echo '' >> /etc/network/interfaces && \
      echo 'iface enp0s31f6 inet manual' >> /etc/network/interfaces && \
      echo '' >> /etc/network/interfaces && \
      echo 'auto vmbr0' >> /etc/network/interfaces && \
      echo 'iface vmbr0 inet static' >> /etc/network/interfaces && \
      echo '  address 167.235.183.103/26' >> /etc/network/interfaces && \
      echo '  gateway 167.235.183.65' >> /etc/network/interfaces && \
      echo '  bridge_ports enp0s31f6' >> /etc/network/interfaces && \
      echo '  bridge_stp off' >> /etc/network/interfaces && \
      echo '  bridge_fd 0' >> /etc/network/interfaces && \
      echo 'nameserver 1.1.1.1' > /etc/resolv.conf"
}

setup_zfs_mirror_pool() {
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "\
      zpool create -f -o ashift=12 tank mirror /dev/sda /dev/sdb && \
      zfs set compression=lz4 tank && \
      zfs create tank/data"
}

final_reboot() {
    sshpass -p "$NEW_ROOT_PASSWORD" ssh -p 5555 -o StrictHostKeyChecking=no root@localhost "poweroff"
}

# Main
get_system_info
get_user_input
prepare_packages
download_proxmox_iso
make_answer_toml
make_autoinstall_iso
install_proxmox
boot_proxmox_with_port_forwarding
configure_proxmox_via_ssh
setup_zfs_mirror_pool
final_reboot
