#!/usr/bin/env bash
###############################################################################
#   All-in-one Hetzner ➜ Proxmox + OPNsense + Headscale/Headplane + Tailscale
#   Author : ChatGPT (2025-04-27) – for Pratik Golecha
###############################################################################
set -euo pipefail
cd /root

# ───────────────────────────  USER CONSTANTS  ────────────────────────────────
OS_DISK="/dev/nvme0n1"                     # Proxmox target disk (DO NOT touch sda/sdb)
ROOT_PWD="Pratik@1412!"
HOSTNAME="proxmox-golecha"
FQDN="pve.local"
EMAIL="padgolecha@gmail.com"
TIMEZONE="Asia/Kolkata"
PRIVATE_SUBNET="192.168.26.0/24"       # LAN behind OPNsense
LAN_IP="192.168.26.1"
HEADSCALE_VM_IP="192.168.26.2"         # static via cloud-init
HEADSCALE_VER="0.25.1"
###############################################################################

CLR() { printf "\033[%sm%s\033[0m\n" "$1" "${2:-}"; }
must_root() { [[ $EUID = 0 ]] || { CLR '1;31' "Run as root"; exit 1; }; }
must_root

###############################################################################
# 0. Detect NIC / IP details in Rescue
###############################################################################
NIC=$(ip -o -4 route show to default | awk '{print $5}')
MAIN_IPV4=$(ip -4 addr show "$NIC" | awk '/inet /{print $2}' | head -n1)
MAIN_IP="${MAIN_IPV4%%/*}"

CLR '1;32' "Boot NIC  : $NIC  |  Rescue IP : $MAIN_IPV4"

###############################################################################
# 1. Install prerequisites for Proxmox Auto-Installer
###############################################################################
CLR '1;34' "Installing helper packages…"
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
  > /etc/apt/sources.list.d/pve.list
curl -fsSL -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg \
  https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg
apt -qq update
apt -yqq install proxmox-auto-install-assistant genisoimage \
               xorriso ovmf sshpass wget curl iptables-persistent

###############################################################################
# 2. Grab latest Proxmox VE ISO
###############################################################################
ISO_URL=$(curl -s https://enterprise.proxmox.com/iso/ \
          | grep -oP 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sort -V | tail -1)
ISO_URL="https://enterprise.proxmox.com/iso/${ISO_URL}"
CLR '1;34' "Downloading Proxmox ISO…  ($ISO_URL)"
wget -qO pve.iso "$ISO_URL"

###############################################################################
# 3. Build answer.toml & autoinstall ISO
###############################################################################
cat > answer.toml <<EOF
[global]
  keyboard   = "en-us"
  country    = "us"
  fqdn       = "$FQDN"
  mailto     = "$EMAIL"
  timezone   = "$TIMEZONE"
  root_password = "$ROOT_PWD"
  reboot_on_error = false
[network]
  source = "from-dhcp"
[disk-setup]
  filesystem = "zfs"
  zfs.raid   = "raid0"
  disk_list  = ["/dev/vda"]
EOF

CLR '1;34' "Building autoinstall ISO…"
proxmox-auto-install-assistant prepare-iso pve.iso \
        --answer-file answer.toml --output pve-auto.iso --fetch-from iso

###############################################################################
# 4. Kick QEMU installer (VNC :0 pw = abcd_123456) onto $OS_DISK
###############################################################################
CLR '1;33' "Proxmox installation in progress (2-5 min)…"
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 4096 \
  -boot d -cdrom ./pve-auto.iso \
  -drive file=$OS_DISK,format=raw,if=virtio \
  -vnc :0,password=on -monitor none -no-reboot <<<"change vnc password abcd_123456"

###############################################################################
# 5. Boot new Proxmox once, SSH port-forward on 5555
###############################################################################
CLR '1;34' "Booting fresh Proxmox to finish config…"
nohup qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 4096 \
  -netdev user,id=net0,hostfwd=tcp::5555-:22 -device e1000,netdev=net0 \
  -drive file=$OS_DISK,format=raw,if=virtio -nographic > /dev/null 2>&1 &
QPID=$!

for i in {1..60}; do
  nc -z localhost 5555 && break; sleep 5
done || { CLR '1;31' "SSH on port 5555 not up"; exit 1; }

###############################################################################
# 6. Push networking template & disable enterprise repos
###############################################################################
CLR '1;34' "Applying initial Proxmox tweaks (ssh)…"
sshpass -p "$ROOT_PWD" ssh -p 5555 -oStrictHostKeyChecking=no root@localhost <<EOS
sed -i 's/^/#/g' /etc/apt/sources.list.d/pve-enterprise.list
sed -i 's/^/#/g' /etc/apt/sources.list.d/ceph.list
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
EOS

###############################################################################
# 7. Build vmbr1/vmbr2, download OPNsense ISO, create VM 100
###############################################################################
setup_bridges_opn_vm() {
sshpass -p "$ROOT_PWD" ssh -p 5555 -oStrictHostKeyChecking=no root@localhost <<'EOSSH'
# ----- add vmbr1 & vmbr2 if absent -----
grep -q "auto vmbr1" /etc/network/interfaces || cat >>/etc/network/interfaces <<EOL

auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0

auto vmbr2
iface vmbr2 inet static
    address 192.168.26.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOL
systemctl restart networking

# ----- fetch OPNsense -----
mkdir -p /var/lib/vz/template/iso
cd       /var/lib/vz/template/iso
ISO=OPNsense-24.1-dvd-amd64.iso
[ -f \$ISO ] || { wget -qO- "https://mirror.dns-root.de/opnsense/releases/24.1/\${ISO}.bz2" | bunzip2 > \$ISO; }

# ----- build seeded config ISO -----
TMP=/tmp/opnseed; mkdir -p \$TMP/conf
cat > \$TMP/conf/config.xml <<'XML'
<?xml version="1.0"?><opnsense><system><hostname>opnsense</hostname>
<domain>lan</domain><username>root</username><password>Pratik@1412!</password>
<timezone>Asia/Kolkata</timezone><dnsserver>1.1.1.1</dnsserver><dnsserver>8.8.8.8</dnsserver></system>
<interfaces><lan><if>vtnet1</if><ipaddr>192.168.26.1</ipaddr><subnet>24</subnet></lan>
<wan><if>vtnet0</if><ipaddr>dhcp</ipaddr></wan></interfaces>
<dhcpd><lan><range><from>192.168.26.50</from><to>192.168.26.100</to></range></lan></dhcpd>
<unbound><dnssec>1</dnssec></unbound>
<shellcmd><cmd>/usr/local/etc/rc.d/tailscaled onestart</cmd></shellcmd></opnsense>
XML
genisoimage -quiet -J -r -o /var/lib/vz/template/iso/opnsense-seed.iso \$TMP

# ----- create VM 100 -----
qm create 100 --name opnsense --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr1 --net1 virtio,bridge=vmbr2 \
  --ide2 local:iso/\$ISO,media=cdrom --ide3 local:iso/opnsense-seed.iso,media=cdrom \
  --scsi0 local-lvm:8 --scsihw virtio-scsi-pci --boot order=ide2
qm start 100
EOSSH
}
setup_bridges_opn_vm

###############################################################################
# 8. Create Headscale / Headplane VM 101 (Ubuntu cloud-init)
###############################################################################
create_headscale_vm() {
sshpass -p "$ROOT_PWD" ssh -p 5555 -oStrictHostKeyChecking=no root@localhost <<'EOSSH'
ISO_DIR=/var/lib/vz/template/iso
IMG=jammy-server-cloudimg-amd64.img
[ -f $ISO_DIR/$IMG ] || wget -qO $ISO_DIR/$IMG https://cloud-images.ubuntu.com/jammy/current/$IMG

qm create 101 --name headscale --memory 1024 --cores 1 \
  --net0 virtio,bridge=vmbr2 --serial0 socket --vga serial0 \
  --scsihw virtio-scsi-pci --boot order=scsi0 \
  --ipconfig0 ip=192.168.26.2/24,gw=192.168.26.1 \
  --sshkey /root/.ssh/authorized_keys
qm importdisk 101 $ISO_DIR/$IMG local-lvm
qm set 101 --scsi0 local-lvm:vm-101-disk-0
qm start 101
EOSSH
}
create_headscale_vm

###############################################################################
# 9. Install Headscale+Headplane via SSH into VM 101
###############################################################################
install_headscale() {
until ssh -oStrictHostKeyChecking=no ubuntu@$HEADSCALE_VM_IP 'echo ok' &>/dev/null; do sleep 5; done
ssh ubuntu@$HEADSCALE_VM_IP <<EOS
sudo apt -qq update
sudo apt -yqq install docker.io docker-compose
mkdir -p ~/headscale && cd ~/headscale
cat > docker-compose.yml <<'DC'
version: "3.9"
services:
  headscale:
    image: headscale/headscale:${HEADSCALE_VER}
    command: headscale serve
    volumes: [ "./data:/etc/headscale" ]
    environment:
      - HEADSCALE_SERVER_URL=http://${HEADSCALE_VM_IP}:8080
    ports:
      - "8080:8080"
      - "3478:3478/udp"
  headplane:
    image: headscale/headscale-ui:latest
    depends_on: [ headscale ]
    environment:
      - HS_SERVER=http://headscale:8080
    ports:
      - "80:80"
DC
sudo docker compose up -d
sudo docker exec \$(sudo docker ps -qf name=headscale_headscale_) headscale users create admin
sudo docker exec \$(sudo docker ps -qf name=headscale_headscale_) \
     headscale preauthkeys create --reusable --ephemeral --user admin --expiration 24h \
     | tee ~/authkey.txt
EOS
}
install_headscale
AUTHKEY=$(ssh ubuntu@$HEADSCALE_VM_IP 'cat ~/authkey.txt' | awk '/^tskey/{print $1}')

###############################################################################
# 10. Join OPNsense to Headscale + enable NAT rules
###############################################################################
join_tailscale_in_opn() {
until sshpass -p "$ROOT_PWD" ssh -oStrictHostKeyChecking=no root@$LAN_IP 'echo ok' &>/dev/null; do sleep 5; done
sshpass -p "$ROOT_PWD" ssh -oStrictHostKeyChecking=no root@$LAN_IP <<EOS
pkg update -f && pkg install -y tailscale
service tailscaled enable && service tailscaled start
tailscale up --login-server http://$HEADSCALE_VM_IP:8080 --authkey $AUTHKEY --ssh --hostname opnsense-fw
EOS
}
join_tailscale_in_opn

# Open ports on Proxmox host for NAT & save
sshpass -p "$ROOT_PWD" ssh -p 5555 -oStrictHostKeyChecking=no root@localhost \
 "iptables -t nat -A POSTROUTING -s $PRIVATE_SUBNET -o vmbr0 -j MASQUERADE &&
  iptables -A INPUT -p tcp -m tcp --dport 8080 -j ACCEPT &&
  iptables -A INPUT -p udp -m udp --dport 3478 -j ACCEPT &&
  netfilter-persistent save"

###############################################################################
# 11. Power-off nested QEMU, reboot bare-metal into Proxmox
###############################################################################
kill $QPID || true
CLR '1;32' ">>> BASE INSTALL FINISHED – rebooting server…"
reboot

###############################################################################
# After reboot, open:
#   Proxmox  : https://$MAIN_IP:8006 (root / $ROOT_PWD)
#   OPNsense : https://$LAN_IP      (root / $ROOT_PWD)
#   Headplane: http://$HEADSCALE_VM_IP  (admin / $ROOT_PWD)
#   Tailnet   pre-auth-key (24 h): $AUTHKEY
###############################################################################
