#!/usr/bin/env bash
#
# Script de configuration du lab réseau sur Fedora :
# - Open vSwitch : ovs-br-mgnt / ovs-br-lan + ports internes
# - IP forwarding
# - NAT avec iptables vers l'interface WAN
# - Persistance via sysctl.d + iptables-services
#
# Usage :
#   sudo ./setup_lab_network.sh
#

set -euo pipefail

### === PARAMÈTRES À ADAPTER SI BESOIN ===============================

# Réseau de management (celui qui sera NATé)
MGMT_NET_CIDR="10.0.10.0/24"
MGMT_BRIDGE_IP="10.0.10.1/24"

# Interface physique côté Internet / LAN principal (celle de ton exemple)
WAN_IFACE="enp0s20f0u4"

# Noms des ponts et interfaces OVS (ceux utilisés dans le cours)
MGMT_BRIDGE="ovs-br-mgnt"
DATA_BRIDGE="ovs-br-lan"

MGMT_IFACE1="mgnt-vm1"
MGMT_IFACE2="mgnt-vm2"
DATA_IFACE1="data-vm1"
DATA_IFACE2="data-vm2"

# Désactiver firewalld et utiliser iptables-services uniquement ?
DISABLE_FIREWALLD=true

### === FONCTIONS UTILITAIRES =======================================

log() {
  echo -e "\n[+] $*\n"
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Ce script doit être exécuté en root. Utilise : sudo $0"
    exit 1
  fi
}

ensure_package() {
  local pkg="$1"
  if ! rpm -q "${pkg}" &>/dev/null; then
    log "Installation du paquet ${pkg}..."
    dnf install -y "${pkg}"
  fi
}

bridge_exists() {
  local br="$1"
  ovs-vsctl br-exists "${br}" &>/dev/null
}

port_exists() {
  local br="$1"
  local port="$2"
  ovs-vsctl list-ports "${br}" 2>/dev/null | grep -qx "${port}"
}

ip_has_addr() {
  local dev="$1"
  local cidr="$2"
  ip -4 addr show dev "${dev}" | grep -q "${cidr}" || return 1
}

iptables_has_rule() {
  # Utilise iptables -C : renvoie 0 si la règle existe, 1 sinon
  if iptables "$@" -C &>/dev/null; then
    return 0
  else
    return 1
  fi
}

### === VÉRIFICATIONS DE BASE =======================================

require_root

log "Vérification de l'existence de l'interface WAN ${WAN_IFACE}..."
if ! ip link show "${WAN_IFACE}" &>/dev/null; then
  echo "ERREUR : l'interface ${WAN_IFACE} n'existe pas."
  echo "Modifie la variable WAN_IFACE en haut du script pour mettre ton interface réelle."
  exit 1
fi

### === INSTALLATION DES PAQUETS NÉCESSAIRES ========================

log "Installation des paquets nécessaires (openvswitch, bridge-utils, iptables-services)..."

ensure_package "openvswitch"
ensure_package "bridge-utils"
ensure_package "iptables-services"

### === GESTION DU FIREWALL (firewalld vs iptables) =================

if [[ "${DISABLE_FIREWALLD}" == "true" ]]; then
  log "Désactivation de firewalld (recommandé si tu utilises iptables-services seul)..."
  systemctl stop firewalld 2>/dev/null || true
  systemctl disable firewalld 2>/dev/null || true
else
  log "ATTENTION : DISABLE_FIREWALLD=false -> firewalld reste actif."
  echo "Il est déconseillé de mixer firewalld et iptables-services sur le même hôte."
fi

log "Activation des services openvswitch et iptables..."
systemctl enable --now openvswitch
systemctl enable --now iptables
systemctl start iptables || true

### === CONFIGURATION OPEN VSWITCH ==================================

log "Création / configuration des ponts OVS..."

# Pont de management
if bridge_exists "${MGMT_BRIDGE}"; then
  log "Le bridge ${MGMT_BRIDGE} existe déjà, je ne le recrée pas."
else
  log "Création du bridge ${MGMT_BRIDGE}..."
  ovs-vsctl add-br "${MGMT_BRIDGE}"
fi

# Pont data
if bridge_exists "${DATA_BRIDGE}"; then
  log "Le bridge ${DATA_BRIDGE} existe déjà, je ne le recrée pas."
else
  log "Création du bridge ${DATA_BRIDGE}..."
  ovs-vsctl add-br "${DATA_BRIDGE}"
fi

# Ports internes de management
if ! port_exists "${MGMT_BRIDGE}" "${MGMT_IFACE1}"; then
  log "Ajout du port interne ${MGMT_IFACE1} sur ${MGMT_BRIDGE}..."
  ovs-vsctl add-port "${MGMT_BRIDGE}" "${MGMT_IFACE1}" -- set interface "${MGMT_IFACE1}" type=internal
fi

if ! port_exists "${MGMT_BRIDGE}" "${MGMT_IFACE2}"; then
  log "Ajout du port interne ${MGMT_IFACE2} sur ${MGMT_BRIDGE}..."
  ovs-vsctl add-port "${MGMT_BRIDGE}" "${MGMT_IFACE2}" -- set interface "${MGMT_IFACE2}" type=internal
fi

# Ports internes data
if ! port_exists "${DATA_BRIDGE}" "${DATA_IFACE1}"; then
  log "Ajout du port interne ${DATA_IFACE1} sur ${DATA_BRIDGE}..."
  ovs-vsctl add-port "${DATA_BRIDGE}" "${DATA_IFACE1}" -- set interface "${DATA_IFACE1}" type=internal
fi

if ! port_exists "${DATA_BRIDGE}" "${DATA_IFACE2}"; then
  log "Ajout du port interne ${DATA_IFACE2} sur ${DATA_BRIDGE}..."
  ovs-vsctl add-port "${DATA_BRIDGE}" "${DATA_IFACE2}" -- set interface "${DATA_IFACE2}" type=internal
fi

# Monter les interfaces
log "Activation des interfaces OVS..."
ip link set "${MGMT_BRIDGE}" up
ip link set "${DATA_BRIDGE}" up
ip link set "${MGMT_IFACE1}" up || true
ip link set "${MGMT_IFACE2}" up || true
ip link set "${DATA_IFACE1}" up || true
ip link set "${DATA_IFACE2}" up || true

# Adresse IP sur le bridge de management (GW du réseau 10.0.10.0/24)
log "Configuration de l'adresse IP du bridge de management ${MGMT_BRIDGE} (${MGMT_BRIDGE_IP})..."
if ip_has_addr "${MGMT_BRIDGE}" "${MGMT_BRIDGE_IP}"; then
  log "L'adresse ${MGMT_BRIDGE_IP} est déjà configurée sur ${MGMT_BRIDGE}."
else
  ip addr add "${MGMT_BRIDGE_IP}" dev "${MGMT_BRIDGE}"
fi

### === IP FORWARDING (NAT) =========================================

log "Activation de l'IP forwarding (net.ipv4.ip_forward=1)..."

# Immédiat
sysctl -w net.ipv4.ip_forward=1

# Persistance via sysctl.d
SYSCTL_FILE="/etc/sysctl.d/99-lab-ip_forward.conf"
echo "net.ipv4.ip_forward = 1" > "${SYSCTL_FILE}"
sysctl -p "${SYSCTL_FILE}" || true

### === RÈGLES IPTABLES DE NAT ======================================

log "Configuration des règles iptables de NAT pour ${MGMT_NET_CIDR} -> ${WAN_IFACE}..."

# 1) POSTROUTING MASQUERADE
if iptables_has_rule -t nat POSTROUTING -s "${MGMT_NET_CIDR}" -o "${WAN_IFACE}" -j MASQUERADE; then
  log "Règle NAT POSTROUTING déjà présente."
else
  iptables -t nat -A POSTROUTING -s "${MGMT_NET_CIDR}" -o "${WAN_IFACE}" -j MASQUERADE
fi

# 2) FORWARD : trafic sortant
if iptables_has_rule FORWARD -s "${MGMT_NET_CIDR}" -o "${WAN_IFACE}" -j ACCEPT; then
  log "Règle FORWARD (sortant) déjà présente."
else
  iptables -A FORWARD -s "${MGMT_NET_CIDR}" -o "${WAN_IFACE}" -j ACCEPT
fi

# 3) FORWARD : trafic retour (ESTABLISHED,RELATED)
if iptables_has_rule FORWARD -d "${MGMT_NET_CIDR}" -m conntrack --ctstate ESTABLISHED,RELATED -i "${WAN_IFACE}" -j ACCEPT; then
  log "Règle FORWARD (retour) déjà présente."
else
  iptables -A FORWARD -d "${MGMT_NET_CIDR}" -m conntrack --ctstate ESTABLISHED,RELATED -i "${WAN_IFACE}" -j ACCEPT
fi

### === PERSISTENCE DES RÈGLES IPTABLES =============================

log "Sauvegarde des règles iptables dans /etc/sysconfig/iptables pour persistance..."

iptables-save > /etc/sysconfig/iptables

log "Redémarrage du service iptables pour vérifier la restauration des règles..."
systemctl restart iptables

### === RÉCAPITULATIF ===============================================

log "Configuration terminée."

echo "Vérifications conseillées :"
echo " 1) ovs-vsctl show"
echo " 2) ip addr show ${MGMT_BRIDGE}"
echo " 3) iptables -t nat -L -n -v"
echo " 4) iptables -L FORWARD -n -v"
echo
echo "Ensuite, configure tes VMs en 10.0.10.x/24 avec comme passerelle ${MGMT_BRIDGE_IP%/*},"
echo "et elles devraient sortir sur Internet via ${WAN_IFACE} (NAT)."
