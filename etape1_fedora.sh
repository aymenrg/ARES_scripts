#!/usr/bin/env bash
set -euo pipefail

### ============================================================================
# Script d'initialisation de l'étape 1 du lab
# - Fedora + KVM + libvirt + Open vSwitch
# - Crée vm1-Host et vm2-Host à partir de l'image Ubuntu noble cloud
# - Configure les bridges OVS et les réseaux libvirt
#
# À lancer en tant qu'utilisateur normal ayant sudo :
#   bash setup_etape1.sh
### ============================================================================

# -----------------------------------------------------------------------------
# Paramètres du lab (adapter si ton TP utilise d'autres adresses)
# -----------------------------------------------------------------------------
MGMT_BR="ovs-br-mgnt"
DATA_BR="ovs-br-lan"
MGMT_IP_CIDR="10.0.10.1/24"
DATA_IP_CIDR="10.0.20.1/24"

VM1_MGMT_IP="10.0.10.11/24"
VM1_DATA_IP="10.0.20.11/24"

VM2_MGMT_IP="10.0.10.21/24"
VM2_DATA_IP="10.0.20.21/24"

IMG_DIR="/var/lib/libvirt/images"
BASE_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
BASE_IMAGE="${IMG_DIR}/noble-server-cloudimg-amd64.img"

VM1_DISK="${IMG_DIR}/vm1-host.qcow2"
VM2_DISK="${IMG_DIR}/vm2-host.qcow2"
VM1_SEED="${IMG_DIR}/vm1-host-seed.iso"
VM2_SEED="${IMG_DIR}/vm2-host-seed.iso"

VM1_NAME="vm1-Host"
VM2_NAME="vm2-Host"

OSINFO="linux2024"   # OS générique récent pour virt-install

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log() {
  echo
  echo "==> $*"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Erreur: la commande '$1' est introuvable. Installe-la puis relance le script." >&2
    exit 1
  fi
}

# Vérifier quelques commandes essentielles
for cmd in sudo curl qemu-img cloud-localds virsh ovs-vsctl ip; do
  need_cmd "$cmd"
done

# -----------------------------------------------------------------------------
# 1. Services de base : libvirtd + openvswitch
# -----------------------------------------------------------------------------
log "Activation des services libvirtd et openvswitch"

sudo systemctl enable --now libvirtd
sudo systemctl enable --now openvswitch

# -----------------------------------------------------------------------------
# 2. Open vSwitch : bridges + IPs
# -----------------------------------------------------------------------------
log "Configuration des bridges Open vSwitch (${MGMT_BR}, ${DATA_BR})"

# Créer les bridges s'ils n'existent pas
if ! sudo ovs-vsctl br-exists "${MGMT_BR}" 2>/dev/null; then
  sudo ovs-vsctl add-br "${MGMT_BR}"
fi

if ! sudo ovs-vsctl br-exists "${DATA_BR}" 2>/dev/null; then
  sudo ovs-vsctl add-br "${DATA_BR}"
fi

# Activer les interfaces
sudo ip link set "${MGMT_BR}" up || true
sudo ip link set "${DATA_BR}" up || true

# Donner les IP aux bridges (re-faites à chaque run, c'est OK)
sudo ip addr flush dev "${MGMT_BR}" || true
sudo ip addr add "${MGMT_IP_CIDR}" dev "${MGMT_BR}"

sudo ip addr flush dev "${DATA_BR}" || true
sudo ip addr add "${DATA_IP_CIDR}" dev "${DATA_BR}"

log "État OVS :"
sudo ovs-vsctl show

# -----------------------------------------------------------------------------
# 3. Image Ubuntu cloud de base
# -----------------------------------------------------------------------------
log "Préparation de l'image cloud Ubuntu noble dans ${IMG_DIR}"

sudo mkdir -p "${IMG_DIR}"

if [ ! -f "${BASE_IMAGE}" ]; then
  log "Téléchargement de ${BASE_IMAGE_URL}"
  sudo curl -L -o "${BASE_IMAGE}" "${BASE_IMAGE_URL}"
else
  log "Image de base déjà présente : ${BASE_IMAGE}"
fi

sudo restorecon -v "${BASE_IMAGE}" || true

# -----------------------------------------------------------------------------
# 4. Disques des VMs vm1-host / vm2-host
# -----------------------------------------------------------------------------
log "Préparation des disques ${VM1_DISK} et ${VM2_DISK}"

if [ ! -f "${VM1_DISK}" ]; then
  log "Création de ${VM1_DISK} à partir de l'image de base"
  sudo cp "${BASE_IMAGE}" "${VM1_DISK}"
  sudo qemu-img resize "${VM1_DISK}" +10G
fi

if [ ! -f "${VM2_DISK}" ]; then
  log "Création de ${VM2_DISK} à partir de l'image de base"
  sudo cp "${BASE_IMAGE}" "${VM2_DISK}"
  sudo qemu-img resize "${VM2_DISK}" +10G
fi

sudo restorecon -v "${VM1_DISK}" "${VM2_DISK}" || true

# -----------------------------------------------------------------------------
# 5. Clé SSH labs-admin
# -----------------------------------------------------------------------------
log "Vérification / création de la clé SSH ~/.ssh/labs-admin"

SSH_KEY="${HOME}/.ssh/labs-admin"
SSH_PUB="${HOME}/.ssh/labs-admin.pub"

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

if [ ! -f "${SSH_PUB}" ]; then
  log "Génération d'une nouvelle paire de clés labs-admin"
  rm -f "${SSH_KEY}" "${SSH_PUB}"
  ssh-keygen -q -t ed25519 -f "${SSH_KEY}" -C "labs-admin" -N ""
else
  log "Clé SSH labs-admin déjà présente, réutilisation"
fi

PUBKEY=$(cat "${SSH_PUB}")

# -----------------------------------------------------------------------------
# 6. Cloud-init pour vm1-host et vm2-host
# -----------------------------------------------------------------------------
log "Génération des fichiers cloud-init pour vm1-host et vm2-host"

CI_VM1_DIR="${HOME}/cloud-init/vm1-host"
CI_VM2_DIR="${HOME}/cloud-init/vm2-host"

mkdir -p "${CI_VM1_DIR}" "${CI_VM2_DIR}"

# vm1-host user-data
cat > "${CI_VM1_DIR}/user-data" <<EOF
#cloud-config
hostname: vm1-host
users:
  - name: root
    ssh-authorized-keys:
      - ${PUBKEY}
disable_root: false
chpasswd:
  expire: false
  users:
    - {name: root, password: root, type: text}
growpart:
  mode: auto
  devices: ["/dev/vda1"]
  ignore_growroot_disabled: false
resize2fs: /dev/vda1
EOF

# vm1-host network-config (on ajustera les noms d'interface dans la VM si besoin)
cat > "${CI_VM1_DIR}/network-config" <<EOF
version: 2
ethernets:
  enp1s0:
    dhcp4: false
    addresses: [${VM1_MGMT_IP}]
    gateway4: ${MGMT_IP_CIDR%%/*}
    nameservers:
      addresses: [1.1.1.1]
  enp2s0:
    dhcp4: false
    dhcp6: false
    addresses: [${VM1_DATA_IP}]
    gateway4: ${DATA_IP_CIDR%%/*}
EOF

# vm2-host user-data
cat > "${CI_VM2_DIR}/user-data" <<EOF
#cloud-config
hostname: vm2-host
users:
  - name: root
    ssh-authorized-keys:
      - ${PUBKEY}
disable_root: false
chpasswd:
  expire: false
  users:
    - {name: root, password: root, type: text}
growpart:
  mode: auto
  devices: ["/dev/vda1"]
  ignore_growroot_disabled: false
resize2fs: /dev/vda1
EOF

# vm2-host network-config
cat > "${CI_VM2_DIR}/network-config" <<EOF
version: 2
ethernets:
  enp1s0:
    dhcp4: false
    addresses: [${VM2_MGMT_IP}]
    gateway4: ${MGMT_IP_CIDR%%/*}
    nameservers:
      addresses: [1.1.1.1]
  enp2s0:
    dhcp4: false
    dhcp6: false
    addresses: [${VM2_DATA_IP}]
    gateway4: ${DATA_IP_CIDR%%/*}
EOF

# -----------------------------------------------------------------------------
# 7. Génération des ISO cloud-init (seed)
# -----------------------------------------------------------------------------
log "Génération des ISO cloud-init (seed) dans ${IMG_DIR}"

sudo cloud-localds --network-config "${CI_VM1_DIR}/network-config" \
  "${VM1_SEED}" \
  "${CI_VM1_DIR}/user-data"

sudo cloud-localds --network-config "${CI_VM2_DIR}/network-config" \
  "${VM2_SEED}" \
  "${CI_VM2_DIR}/user-data"

sudo restorecon -v "${VM1_SEED}" "${VM2_SEED}" || true

# -----------------------------------------------------------------------------
# 8. Réseaux libvirt liés aux bridges OVS
# -----------------------------------------------------------------------------
log "Création / démarrage des réseaux libvirt ovs-mgnt et ovs-data"

# ovs-mgnt
if ! sudo virsh net-info ovs-mgnt >/dev/null 2>&1; then
  cat > /tmp/ovs-mgnt.xml <<EOF
<network>
  <name>ovs-mgnt</name>
  <forward mode='bridge'/>
  <bridge name='${MGMT_BR}'/>
  <virtualport type='openvswitch'/>
</network>
EOF
  sudo virsh net-define /tmp/ovs-mgnt.xml
fi
sudo virsh net-start ovs-mgnt 2>/dev/null || true
sudo virsh net-autostart ovs-mgnt || true

# ovs-data
if ! sudo virsh net-info ovs-data >/dev/null 2>&1; then
  cat > /tmp/ovs-data.xml <<EOF
<network>
  <name>ovs-data</name>
  <forward mode='bridge'/>
  <bridge name='${DATA_BR}'/>
  <virtualport type='openvswitch'/>
</network>
EOF
  sudo virsh net-define /tmp/ovs-data.xml
fi
sudo virsh net-start ovs-data 2>/dev/null || true
sudo virsh net-autostart ovs-data || true

# -----------------------------------------------------------------------------
# 9. Création des VMs vm1-Host et vm2-Host si elles n'existent pas
# -----------------------------------------------------------------------------
log "Création des VMs ${VM1_NAME} et ${VM2_NAME} (si nécessaires)"

# vm1-Host
if ! sudo virsh dominfo "${VM1_NAME}" >/dev/null 2>&1; then
  log "Création de ${VM1_NAME}"
  sudo virt-install \
    --name "${VM1_NAME}" \
    --memory 3072 \
    --vcpus 4 \
    --import \
    --osinfo "${OSINFO}" \
    --disk path="${VM1_DISK}",format=qcow2,bus=virtio \
    --disk path="${VM1_SEED}",device=cdrom \
    --network network=ovs-mgnt,mac=52:54:00:01:10:11,model=virtio \
    --network network=ovs-data,mac=52:54:00:01:20:11,model=virtio \
    --noautoconsole
else
  log "VM ${VM1_NAME} déjà définie, aucune recréation"
fi

sudo virsh start "${VM1_NAME}" 2>/dev/null || true
sudo virsh autostart "${VM1_NAME}" || true

# vm2-Host
if ! sudo virsh dominfo "${VM2_NAME}" >/dev/null 2>&1; then
  log "Création de ${VM2_NAME}"
  sudo virt-install \
    --name "${VM2_NAME}" \
    --memory 3072 \
    --vcpus 4 \
    --import \
    --osinfo "${OSINFO}" \
    --disk path="${VM2_DISK}",format=qcow2,bus=virtio \
    --disk path="${VM2_SEED}",device=cdrom \
    --network network=ovs-mgnt,mac=52:54:00:02:10:21,model=virtio \
    --network network=ovs-data,mac=52:54:00:02:20:21,model=virtio \
    --noautoconsole
else
  log "VM ${VM2_NAME} déjà définie, aucune recréation"
fi

sudo virsh start "${VM2_NAME}" 2>/dev/null || true
sudo virsh autostart "${VM2_NAME}" || true

# -----------------------------------------------------------------------------
# 10. Récap
# -----------------------------------------------------------------------------
log "Récapitulatif :"
echo " - Bridges OVS :"
ip addr show "${MGMT_BR}" || true
ip addr show "${DATA_BR}" || true

echo
echo " - Réseaux libvirt :"
sudo virsh net-list --all || true

echo
echo " - VMs :"
sudo virsh list --all || true

echo
echo "Script terminé."
echo "Une fois les VMs démarrées, corrige si besoin les noms d'interfaces dans /etc/netplan/50-cloud-init.yaml"
echo "dans chaque VM (via virt-viewer ou SSH) pour que 10.0.10.11/21 et 10.0.20.11/21 soient bien appliquées."
echo "Ensuite, depuis l'hôte, tu pourras faire :"
echo "  ssh -i ~/.ssh/labs-admin root@10.0.10.11"
echo "  ssh -i ~/.ssh/labs-admin root@10.0.10.21"
