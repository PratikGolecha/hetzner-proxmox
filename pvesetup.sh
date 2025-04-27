#!/usr/bin/env bash
###############################################################################
# Hetzner ➜ Proxmox 8 + OPNsense 24.1 + Headscale/Headplane + Tailscale
# Hardened with github.com/Regis-Loyaute/hetzner-proxmox-pfsense-opnsense
###############################################################################
set -euo pipefail
cd /root

: "${PUBIP:?export PUBIP=…}"; : "${SSHPORT:?export SSHPORT=…}"

# ─────────────────── constants ───────────────────
OS_DISK="/dev/nvme0n1"        ; ROOT_PWD="Pratik@1412!" ; TZ="Asia/Kolkata"
WAN_CIDR="10.0.0.0/30"        ; PVE_WAN_IP="10.0.0.1" ; OPN_WAN_IP="10.0.0.2"
LAN_CIDR="192.168.10.0/24"    ; LAN_GW="192.168.10.1" ; HS_IP="192.168.10.2"
HS_VER="0.25.1"

# ─────────────────── rescue prerequisites ───────────────────
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
   > /etc/apt/sources.list.d/pve.list
curl -fsSL -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg \
   https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg
export DEBIAN_FRONTEND=noninteractive
apt -qq update
apt -yqq install proxmox-auto-install-assistant genisoimage xorriso ovmf \
                sshpass wget curl iptables-persistent fail2ban
unset DEBIAN_FRONTEND

# ─────────────────── unattended Proxmox ISO ───────────────────
ISO=$(curl -s https://enterprise.proxmox.com/iso/ |
      grep -oP 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sort -V | tail -1)
wget -qO pve.iso "https://enterprise.proxmox.com/iso/$ISO"

cat >answer.toml <<'EOF'
[global]
keyboard        = "en-us"
country         = "us"
fqdn            = "pve.local"
mailto          = "padgolecha@gmail.com"
timezone        = "Asia/Kolkata"
root_password   = "Pratik@1412!"
reboot_on_error = false

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "zfs"
zfs.raid   = "raid0"
disk_list  = ["/dev/vda"]
EOF


proxmox-auto-install-assistant prepare-iso pve.iso \
        --answer-file answer.toml --output auto.iso --fetch-from iso

# ─────────────────── Proxmox install in nested QEMU ───────────────────
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 4096 \
  -boot d -cdrom auto.iso -drive file=$OS_DISK,format=raw,if=virtio \
  -vnc :0,password=on -monitor none -no-reboot <<<"change vnc password abcd_123456"

# ─────────────────── first boot (SSH → 5555) ───────────────────
nohup qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 4096 \
  -netdev user,id=net0,hostfwd=tcp::5555-:22 -device e1000,netdev=net0 \
  -drive file=$OS_DISK,format=raw,if=virtio -nographic >/dev/null 2>&1 &
QPID=$!
for i in {1..60}; do nc -z localhost 5555 && break; sleep 5; done

# ─────────────────── harden host (iptables + fail2ban) ───────────────────
sshpass -p "$ROOT_PWD" ssh -p 5555 -oStrictHostKeyChecking=no root@localhost <<EOS
sed -i 's/^/#/' /etc/apt/sources.list.d/pve-enterprise.list
sed -i 's/^/#/' /etc/apt/sources.list.d/ceph.list
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf

curl -fsSL -o /root/iptables-regis.sh \
  https://raw.githubusercontent.com/Regis-Loyaute/hetzner-proxmox-pfsense-opnsense/main/iptables-script/iptables.sh
chmod +x /root/iptables-regis.sh
PUBIP=$PUBIP SSHPORT=$SSHPORT /root/iptables-regis.sh
netfilter-persistent save
systemctl enable --now fail2ban
echo "@reboot /root/iptables-regis.sh" >> /var/spool/cron/crontabs/root
sysctl -w net.ipv4.ip_forward=1
EOS

# ─────────────────── vmbr1 / vmbr2 + OPNsense VM 100 ───────────────────
sshpass -p "$ROOT_PWD" ssh -p 5555 -oStrictHostKeyChecking=no root@localhost <<EOS
grep -q vmbr2 /etc/network/interfaces || cat >>/etc/network/interfaces <<EOL

auto vmbr1
iface vmbr1 inet static
  address $PVE_WAN_IP/30
  bridge-ports none
  bridge-stp off
  bridge-fd 0

auto vmbr2
iface vmbr2 inet static
  address $LAN_GW/24
  bridge-ports none
  bridge-stp off
  bridge-fd 0
EOL
systemctl restart networking

ISO_DIR=/var/lib/vz/template/iso
ISO=OPNsense-24.1-dvd-amd64.iso
mkdir -p \$ISO_DIR
[ -f \$ISO_DIR/\$ISO ] || wget -qO- \
  https://mirror.dns-root.de/opnsense/releases/24.1/\$ISO.bz2 | bunzip2 >\$ISO_DIR/\$ISO

mkdir -p /tmp/opnseed/conf
cat >/tmp/opnseed/conf/config.xml <<XML
<?xml version="1.0"?><opnsense>
<system><hostname>opnsense</hostname><domain>lan</domain>
<username>root</username><password>$ROOT_PWD</password><timezone>$TZ</timezone></system>
<interfaces>
  <lan><if>vtnet1</if><ipaddr>$LAN_GW</ipaddr><subnet>24</subnet></lan>
  <wan><if>vtnet0</if><ipaddr>$OPN_WAN_IP</ipaddr><subnet>30</subnet></wan>
</interfaces>
<dhcpd><lan><range><from>192.168.10.50</from><to>192.168.10.100</to></range></lan></dhcpd>
</opnsense>
XML
genisoimage -quiet -J -r -o \$ISO_DIR/opnseed.iso /tmp/opnseed

qm create 100 --name opnsense --memory 3072 --cores 2 \
  --net0 virtio,bridge=vmbr1 --net1 virtio,bridge=vmbr2 \
  --ide2 local:iso/\$ISO,media=cdrom --ide3 local:iso/opnseed.iso,media=cdrom \
  --scsi0 local-lvm:8 --scsihw virtio-scsi-pci --boot order=ide2
qm start 100
EOS

# ─────────────────── Headscale / Headplane VM 101 ───────────────────
sshpass -p "$ROOT_PWD" ssh -p 5555 -oStrictHostKeyChecking=no root@localhost <<EOS
ISO_DIR=/var/lib/vz/template/iso ; IMG=jammy.img
[ -f \$ISO_DIR/\$IMG ] || wget -qO \$ISO_DIR/\$IMG \
  https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
qm create 101 --name headscale --memory 1024 --cores 1 \
  --net0 virtio,bridge=vmbr2 --serial0 socket --vga serial0 \
  --scsihw virtio-scsi-pci --boot order=scsi0 \
  --ipconfig0 ip=$HS_IP/24,gw=$LAN_GW --cipassword "$ROOT_PWD"
qm importdisk 101 \$ISO_DIR/\$IMG local-lvm
qm set 101 --scsi0 local-lvm:vm-101-disk-0
qm start 101
EOS

until ssh -oStrictHostKeyChecking=no ubuntu@$HS_IP 'echo ok' &>/dev/null; do sleep 5; done
ssh ubuntu@$HS_IP <<EOS
sudo apt -qq update && sudo apt -yqq install docker.io docker-compose
mkdir -p ~/hs && cd ~/hs
cat >docker-compose.yml <<DC
version: "3"
services:
  headscale:
    image: headscale/headscale:$HS_VER
    command: headscale serve
    volumes: ["./data:/etc/headscale"]
    ports: ["8080:8080","3478:3478/udp"]
  headplane:
    image: ghcr.io/tale/headplane:0.5.10
    depends_on:
      - headscale
    environment:
      - HEADSCALE_URL=http://headscale:8080
    ports: ["80:80"]
DC
sudo docker compose up -d
sudo docker exec \$(sudo docker ps -qf name=headscale_headscale_) headscale users create admin
sudo docker exec \$(sudo docker ps -qf name=headscale_headscale_) \
  headscale preauthkeys create --reusable --ephemeral --user admin --expiration 24h \
  | tee ~/authkey.txt
EOS
AUTHKEY=$(ssh ubuntu@$HS_IP cat ~/hs/authkey.txt | grep -o 'tskey.*')

# ─────────────────── Tailscale plugin in OPNsense ───────────────────
until sshpass -p "$ROOT_PWD" ssh -oStrictHostKeyChecking=no root@$LAN_GW 'echo ok' &>/dev/null; do sleep 5; done
sshpass -p "$ROOT_PWD" ssh -oStrictHostKeyChecking=no root@$LAN_GW <<EOS
pkg update -f
pkg install -y os-tailscale-devel
service tailscaled enable && service tailscaled start
tailscale up --login-server http://$HS_IP:8080 --authkey $AUTHKEY --ssh \
             --hostname opnsense-fw
EOS

# ─────────────────── reboot into production ───────────────────
kill $QPID || true
echo -e "\e[32mFinished; rebooting into Proxmox …\e[0m"
reboot
