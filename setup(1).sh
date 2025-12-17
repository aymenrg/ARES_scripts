#!/usr/bin/env bash

# Ajuste si besoin (ton cas: wlp3s0)
WIFI_IF="${WIFI_IF:-wlp3s0}"

MGNT_BR="ovs-br-mgnt"
LAN_BR="ovs-br-lan"

MGNT_IP="10.0.10.1/24"
LAN_IP="10.0.20.1/24"

echo "[1/6] Install packages"
sudo apt update
sudo apt install -y \
  qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
  openvswitch-switch nftables git curl

echo "[2/6] Enable services"
sudo systemctl enable --now libvirtd
sudo systemctl enable --now openvswitch-switch

echo "[3/6] Create OVS bridges + IPs"
sudo ovs-vsctl --may-exist add-br "$MGNT_BR"
sudo ip link set "$MGNT_BR" up
sudo ip addr add "$MGNT_IP" dev "$MGNT_BR" 2>/dev/null || true

sudo ovs-vsctl --may-exist add-br "$LAN_BR"
sudo ip link set "$LAN_BR" up
sudo ip addr add "$LAN_IP" dev "$LAN_BR" 2>/dev/null || true

echo "[4/6] Add internal ports (no IPv4 needed on them)"
sudo ovs-vsctl --may-exist add-port "$MGNT_BR" mgnt-vm1 -- set interface mgnt-vm1 type=internal
sudo ovs-vsctl --may-exist add-port "$MGNT_BR" mgnt-vm2 -- set interface mgnt-vm2 type=internal
sudo ip link set mgnt-vm1 up
sudo ip link set mgnt-vm2 up

sudo ovs-vsctl --may-exist add-port "$LAN_BR" data-vm1 -- set interface data-vm1 type=internal
sudo ovs-vsctl --may-exist add-port "$LAN_BR" data-vm2 -- set interface data-vm2 type=internal
sudo ip link set data-vm1 up
sudo ip link set data-vm2 up

echo "[5/6] Enable IPv4 forwarding (persistent)"
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-areslab-forward.conf >/dev/null
sudo sysctl --system >/dev/null

echo "[6/6] NAT 10.0.20.0/24 -> ${WIFI_IF} (persistent via nftables)"
sudo tee /etc/nftables.conf >/dev/null <<EONFT
flush ruleset
table inet areslab {
  chain forward {
    type filter hook forward priority 0; policy drop;
    iifname "${LAN_BR}" oifname "${WIFI_IF}" accept
    iifname "${WIFI_IF}" oifname "${LAN_BR}" ct state established,related accept
  }
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "${WIFI_IF}" ip saddr 10.0.20.0/24 masquerade
  }
}
EONFT

sudo systemctl enable --now nftables
sudo nft -f /etc/nftables.conf >/dev/null

echo "DONE. Summary:"
sudo ovs-vsctl show
ip -br a | egrep "${WIFI_IF}|${MGNT_BR}|${LAN_BR}|mgnt-vm|data-vm" || true
