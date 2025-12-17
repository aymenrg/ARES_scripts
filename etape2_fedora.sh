#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Script d'automatisation de l'ÉTAPE 2 dans vm1-Host
#
# À lancer DANS vm1-Host, en root :
#   ssh -i ~/.ssh/labs-admin root@10.0.10.11
#   bash /root/setup_etape2.sh
#
# Ce script :
#  - installe les paquets (OVS, KVM, Libvirt, cloud-image-utils, virtinst)
#  - configure les ponts OVS internes (ovs-mgnt, ovs-lan-vm, ovs-br0 + gre0)
#  - crée les réseaux Libvirt (vm-mgmt, vm-lan, vm-data)
#  - télécharge l'image Alpine cloud
#  - crée vm-mgnt et vm1-router (disques, cloud-init, virt-install)
#
# Basé sur etap2.pdf / arch_etape_2.pdf
###############################################################################

#----------------------------- Vérifs de base ---------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Ce script doit être exécuté en root (sudo -i puis bash setup_etape2.sh)" >&2
  exit 1
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Erreur: commande requise manquante: $1" >&2
    exit 1
  fi
}

for cmd in apt ovs-vsctl ip virsh cloud-localds qemu-img curl systemctl; do
  need_cmd "$cmd"
done

log() {
  echo
  echo "==> $*"
}

#----------------------------- Paramètres lab ---------------------------------

# IP déjà utilisées à l'étape 1
MGMT_IP_CIDR="10.0.10.11/24"
DATA_IP_CIDR="10.0.20.11/24"

# Plan étape 2 (Alpine internes)
VM_MGMT_IP_CIDR="10.0.10.31/24"
VM_MGMT_GW="10.0.10.1"
VM_MGMT_DNS="10.0.10.1"

ROUTER_ETH0_IP_CIDR="10.0.30.2/24"
ROUTER_ETH0_GW="10.0.30.1"
ROUTER_ETH0_DNS="1.1.1.1"
ROUTER_ETH1_IP_CIDR="172.16.30.1/24"

GRE_REMOTE_IP="10.0.30.3"  # Adresse côté vm2-Host (sera utilisée à l'étape 3)

# Ponts OVS locaux (dans vm1-Host)
BR_MGMT="ovs-mgnt"
BR_LAN="ovs-lan-vm"
BR_BR0="ovs-br0"

# Réseaux Libvirt internes
NET_MGMT="vm-mgmt"
NET_LAN="vm-lan"
NET_DATA="vm-data"

# Disques / images
IMAGES_DIR="/var/lib/libvirt/images"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/cloud/nocloud_alpine-3.22.2-x86_64-bios-cloudinit-r0.qcow2"
ALPINE_BASE="${IMAGES_DIR}/nocloud_alpine-3.22.2-x86_64-bios-cloudinit-r0.qcow2"

VM1_MGMT_DISK="${IMAGES_DIR}/vm1-mgmt.qcow2"
VM1_ROUTER_DISK="${IMAGES_DIR}/vm1-router.qcow2"

SEED_MGMT="/var/lib/libvirt/seedmgmt.iso"
SEED_ROUTER="/var/lib/libvirt/seedrouter.iso"

VM_MGMT_NAME="vm-mgnt"
VM_ROUTER_NAME="vm1-router"

OSINFO_ALPINE="alpinelinux3.19"

#-------------------------- Détection interfaces ------------------------------

detect_if_for_ip() {
  local cidr="$1"
  ip -o -4 addr show | awk -v ip="$cidr" '$4 == ip { print $2; exit }'
}

log "Détection des interfaces réseau (management / data) dans vm1-Host"

MGMT_IF="$(detect_if_for_ip "${MGMT_IP_CIDR}")"
DATA_IF="$(detect_if_for_ip "${DATA_IP_CIDR}")"

# Valeurs de secours si la détection échoue (adapter si besoin)
if [[ -z "${MGMT_IF}" ]]; then
  MGMT_IF="eth1"
  echo "Attention: interface management non détectée, utilisation par défaut: ${MGMT_IF}"
fi

if [[ -z "${DATA_IF}" ]]; then
  DATA_IF="eth0"
  echo "Attention: interface data non détectée, utilisation par défaut: ${DATA_IF}"
fi

echo "Interface management détectée/supposée : ${MGMT_IF} (${MGMT_IP_CIDR})"
echo "Interface data détectée/supposée      : ${DATA_IF} (${DATA_IP_CIDR})"

#-------------------------- Préparation système --------------------------------

log "Mise à jour des paquets et installation des dépendances (apt, OVS, KVM, Libvirt, cloud-image-utils, virtinst)"

apt update -y
apt install -y \
  openvswitch-switch bridge-utils \
  qemu-kvm libvirt-daemon-system \
  cloud-image-utils virtinst

log "Activation des services libvirtd et openvswitch-switch"
systemctl enable --now libvirtd
systemctl enable --now openvswitch-switch

#-------------------------- Configuration OVS interne --------------------------

log "Configuration des ponts OVS internes (${BR_MGMT}, ${BR_LAN}, ${BR_BR0})"

# Créer les bridges s'ils n'existent pas
if ! ovs-vsctl br-exists "${BR_MGMT}" 2>/dev/null; then
  ovs-vsctl add-br "${BR_MGMT}"
fi

if ! ovs-vsctl br-exists "${BR_LAN}" 2>/dev/null; then
  ovs-vsctl add-br "${BR_LAN}"
fi

if ! ovs-vsctl br-exists "${BR_BR0}" 2>/dev/null; then
  ovs-vsctl add-br "${BR_BR0}"
fi

# Attacher les interfaces physiques
if [[ "${MGMT_IF}" != "${BR_MGMT}" ]]; then
  if ! ovs-vsctl list-ports "${BR_MGMT}" | grep -qx "${MGMT_IF}"; then
    ovs-vsctl add-port "${BR_MGMT}" "${MGMT_IF}"
  fi
else
  echo "MGMT_IF=${MGMT_IF} est déjà le bridge ${BR_MGMT}, aucun add-port nécessaire."
fi


if ! ovs-vsctl list-ports "${BR_BR0}" | grep -qx "${DATA_IF}"; then
  ovs-vsctl add-port "${BR_BR0}" "${DATA_IF}"
fi

# Port GRE vers vm2-Host
if ! ovs-vsctl list interface gre0 >/dev/null 2>&1; then
  ovs-vsctl add-port "${BR_BR0}" gre0 \
    -- set interface gre0 type=gre options:remote_ip="${GRE_REMOTE_IP}"
fi

# Déplacer l'IP de management de l'interface physique vers le bridge ovs-mgnt
log "Déplacement de l'IP de management (${MGMT_IP_CIDR}) de ${MGMT_IF} vers ${BR_MGMT}"

ip addr flush dev "${MGMT_IF}" || true
ip addr add "${MGMT_IP_CIDR}" dev "${BR_MGMT}"
ip link set dev "${BR_MGMT}" up

log "État des ponts OVS :"
ovs-vsctl show

#--------------------- Réseaux Libvirt (vm-mgmt, vm-lan, vm-data) -------------

log "Création / démarrage des réseaux Libvirt (${NET_MGMT}, ${NET_LAN}, ${NET_DATA})"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# vm-mgmt
if ! virsh net-info "${NET_MGMT}" >/dev/null 2>&1; then
  cat > "${tmpdir}/vm-mgmt.xml" <<EOF
<network>
  <name>${NET_MGMT}</name>
  <forward mode='bridge'/>
  <bridge name='${BR_MGMT}'/>
  <virtualport type='openvswitch'/>
</network>
EOF
  virsh net-define "${tmpdir}/vm-mgmt.xml"
fi
virsh net-start "${NET_MGMT}" 2>/dev/null || true
virsh net-autostart "${NET_MGMT}" || true

# vm-lan
if ! virsh net-info "${NET_LAN}" >/dev/null 2>&1; then
  cat > "${tmpdir}/vm-lan.xml" <<EOF
<network>
  <name>${NET_LAN}</name>
  <forward mode='bridge'/>
  <bridge name='${BR_LAN}'/>
  <virtualport type='openvswitch'/>
</network>
EOF
  virsh net-define "${tmpdir}/vm-lan.xml"
fi
virsh net-start "${NET_LAN}" 2>/dev/null || true
virsh net-autostart "${NET_LAN}" || true

# vm-data
if ! virsh net-info "${NET_DATA}" >/dev/null 2>&1; then
  cat > "${tmpdir}/vm-data.xml" <<EOF
<network>
  <name>${NET_DATA}</name>
  <forward mode='bridge'/>
  <bridge name='${BR_BR0}'/>
  <virtualport type='openvswitch'/>
</network>
EOF
  virsh net-define "${tmpdir}/vm-data.xml"
fi
virsh net-start "${NET_DATA}" 2>/dev/null || true
virsh net-autostart "${NET_DATA}" || true

log "Réseaux Libvirt activés :"
virsh net-list --all

#--------------------- Image Alpine et disques des VMs internes ---------------

log "Téléchargement de l'image Alpine cloud (si nécessaire) dans ${IMAGES_DIR}"

mkdir -p "${IMAGES_DIR}"

cd "${IMAGES_DIR}"

if [[ ! -f "${ALPINE_BASE}" ]]; then
  curl -LO "${ALPINE_URL}"
fi

if [[ ! -f "${VM1_MGMT_DISK}" ]]; then
  cp "${ALPINE_BASE}" "${VM1_MGMT_DISK}"
  qemu-img resize "${VM1_MGMT_DISK}" +50M
fi

if [[ ! -f "${VM1_ROUTER_DISK}" ]]; then
  cp "${ALPINE_BASE}" "${VM1_ROUTER_DISK}"
  qemu-img resize "${VM1_ROUTER_DISK}" +50M
fi

#--------------------- Récupération de la clé SSH publique --------------------

log "Récupération de la clé SSH à injecter dans les VMs (cloud-init)"

PUBKEY=""

if [[ -f /root/.ssh/authorized_keys ]]; then
  PUBKEY="$(head -n1 /root/.ssh/authorized_keys)"
fi

if [[ -z "${PUBKEY}" ]] && [[ -f /root/.ssh/id_rsa.pub ]]; then
  PUBKEY="$(cat /root/.ssh/id_rsa.pub)"
fi

if [[ -z "${PUBKEY}" ]]; then
  echo "Erreur: impossible de trouver une clé publique à injecter (ni /root/.ssh/authorized_keys ni /root/.ssh/id_rsa.pub)" >&2
  echo "Copie ta clé publique dans /root/.ssh/authorized_keys puis relance le script." >&2
  exit 1
fi

echo "Clé publique détectée :"
echo "  ${PUBKEY}"

#--------------------- Cloud-init pour vm-mgnt --------------------------------

log "Génération des fichiers cloud-init pour ${VM_MGMT_NAME}"

CI_VM_MGMT_DIR="/root/cloud-init/vm1-mgmt"
mkdir -p "${CI_VM_MGMT_DIR}"

cat > "${CI_VM_MGMT_DIR}/user-data" <<EOF
#cloud-config
hostname: vm-mgnt
users:
  - name: ops
    shell: /bin/ash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${PUBKEY}
growpart:
  mode: auto
  devices: ["/dev/vda1"]
  ignore_growroot_disabled: false
resize2fs: /dev/vda1
chpasswd:
  expire: false
  users:
    - {name: root, password: root, type: text}
runcmd:
  - rc-service networking restart
EOF

cat > "${CI_VM_MGMT_DIR}/network-config" <<EOF
version: 2
ethernets:
  eth0:
    dhcp4: false
    addresses: [${VM_MGMT_IP_CIDR}]
    gateway4: ${VM_MGMT_GW}
    nameservers:
      addresses: [${VM_MGMT_DNS}]
EOF

cloud-localds \
  --network-config "${CI_VM_MGMT_DIR}/network-config" \
  "${SEED_MGMT}" \
  "${CI_VM_MGMT_DIR}/user-data"

#--------------------- Cloud-init pour vm1-router -----------------------------

log "Génération des fichiers cloud-init pour ${VM_ROUTER_NAME}"

CI_VM_ROUTER_DIR="/root/cloud-init/vm1-router"
mkdir -p "${CI_VM_ROUTER_DIR}"

cat > "${CI_VM_ROUTER_DIR}/user-data" <<EOF
#cloud-config
hostname: vm1-router
users:
  - name: ops
    shell: /bin/ash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${PUBKEY}
growpart:
  mode: auto
  devices: ["/dev/vda1"]
  ignore_growroot_disabled: false
resize2fs: /dev/vda1
chpasswd:
  expire: false
  users:
    - {name: root, password: root, type: text}
runcmd:
  - rc-service networking restart
  - sysctl -w net.ipv4.ip_forward=1
packages:
  - iptables
EOF

cat > "${CI_VM_ROUTER_DIR}/network-config" <<EOF
version: 2
ethernets:
  eth0:
    dhcp4: false
    addresses: [${ROUTER_ETH0_IP_CIDR}]
    gateway4: ${ROUTER_ETH0_GW}
    nameservers:
      addresses: [${ROUTER_ETH0_DNS}]
  eth1:
    dhcp4: false
    addresses: [${ROUTER_ETH1_IP_CIDR}]
EOF

cloud-localds \
  --network-config "${CI_VM_ROUTER_DIR}/network-config" \
  "${SEED_ROUTER}" \
  "${CI_VM_ROUTER_DIR}/user-data"

#--------------------- Création des VMs (virt-install) ------------------------

log "Création / démarrage de la VM ${VM_MGMT_NAME}"

if ! virsh dominfo "${VM_MGMT_NAME}" >/dev/null 2>&1; then
  virt-install \
    --name "${VM_MGMT_NAME}" \
    --memory 256 \
    --vcpus 1 \
    --import \
    --osinfo "${OSINFO_ALPINE}" \
    --disk path="${VM1_MGMT_DISK}",format=qcow2 \
    --disk path="${SEED_MGMT}",device=cdrom \
    --network network="${NET_MGMT}",mac=52:54:00:11:00:01,model=virtio \
    --noautoconsole
fi

virsh start "${VM_MGMT_NAME}" 2>/dev/null || true
virsh autostart "${VM_MGMT_NAME}" || true

log "Création / démarrage de la VM ${VM_ROUTER_NAME}"

if ! virsh dominfo "${VM_ROUTER_NAME}" >/dev/null 2>&1; then
  virt-install \
    --name "${VM_ROUTER_NAME}" \
    --memory 256 \
    --vcpus 1 \
    --import \
    --osinfo "${OSINFO_ALPINE}" \
    --disk path="${VM1_ROUTER_DISK}",format=qcow2 \
    --disk path="${SEED_ROUTER}",device=cdrom \
    --network network="${NET_DATA}",mac=52:54:00:11:30:10,model=virtio \
    --network network="${NET_LAN}",mac=52:54:00:11:30:20,model=virtio \
    --noautoconsole
fi

virsh start "${VM_ROUTER_NAME}" 2>/dev/null || true
virsh autostart "${VM_ROUTER_NAME}" || true

#--------------------- Récapitulatif ------------------------------------------

log "Récapitulatif :"

echo
echo "Ponts OVS :"
ovs-vsctl show

echo
echo "Réseaux Libvirt :"
virsh net-list --all

echo
echo "VMs :"
virsh list --all

cat <<EOF

Étape 2 terminée (côté vm1-Host) :

- vm-mgnt (10.0.10.31/24, réseau ${NET_MGMT}) est créée et démarrée.
- vm1-router (10.0.30.2/24 et 172.16.30.1/24, réseaux ${NET_DATA}/${NET_LAN}) est créée et démarrée.
- ovs-mgnt, ovs-lan-vm et ovs-br0 sont configurés, avec un port GRE gre0 vers ${GRE_REMOTE_IP}.

Prochaines vérifications à faire manuellement :
  * ping 10.0.10.31 depuis vm1-Host
  * ping 10.0.10.11 depuis vm-mgnt
  * ping 10.0.30.2 depuis vm1-Host

EOF
