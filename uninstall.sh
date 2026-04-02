#!/bin/bash
# =============================================================
# RPi Link v4 — Uninstall Script
# sudo bash uninstall.sh
# =============================================================
set -e

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'

info() { echo -e "${GRN}[✓]${NC} $1"; }
warn() { echo -e "${YLW}[!]${NC} $1"; }
step() { echo -e "\n${CYN}${BLD}── $1 ──${NC}"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}[✗]${NC} Run as root: sudo bash uninstall.sh"; exit 1; }

echo -e "\n${BLD}RPi Link v4 — Uninstall${NC}\n"
read -p "Remove all RPi Link services, configs, and app? [y/N] " -n1 yn; echo
[[ "$yn" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

step "Stopping services"
for svc in rpi-link rpi-link-hotspot rpi-link-xvfb; do
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    info "Stopped + disabled $svc"
done

step "Removing unit files"
for f in /etc/systemd/system/rpi-link.service \
          /etc/systemd/system/rpi-link-hotspot.service \
          /etc/systemd/system/rpi-link-xvfb.service; do
    rm -f "$f" && info "Removed $f"
done
systemctl daemon-reload; info "systemd reloaded"

step "Removing app and scripts"
rm -rf /opt/rpi-link
rm -f  /usr/local/sbin/rpi-link-hotspot-up.sh
rm -f  /usr/local/sbin/rpi-link-nat.sh
info "App removed"

step "Removing network config"
rm -f /etc/hostapd/rpi-link.conf
rm -f /etc/dnsmasq.d/rpi-link-hotspot.conf
rm -f /etc/NetworkManager/conf.d/rpi-link-hotspot.conf
info "Network config removed"

step "Removing iptables NAT rules (best effort)"
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true
info "iptables flushed"

step "Python packages (optional)"
read -p "Remove Python packages (flask, flask-sock, pillow)? [y/N] " -n1 p; echo
if [[ "$p" =~ ^[Yy]$ ]]; then
    pip3 uninstall -y flask flask-sock simple-websocket pillow 2>/dev/null || true
    info "Python packages removed"
fi

echo ""
echo -e "${GRN}${BLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${GRN}${BLD}║  ✓  RPi Link v4 fully removed!           ║${NC}"
echo -e "${GRN}${BLD}║  → sudo reboot to finish cleanup         ║${NC}"
echo -e "${GRN}${BLD}╚══════════════════════════════════════════╝${NC}"
