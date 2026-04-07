#!/usr/bin/env bash
# =============================================================================
#  ██████╗ ██████╗ ██████╗ ███████╗██████╗ ██╗
# ██╔════╝██╔═══██╗██╔══██╗██╔════╝██╔══██╗██║
# ██║     ██║   ██║██║  ██║█████╗  ██████╔╝██║
# ██║     ██║   ██║██║  ██║██╔══╝  ██╔═══╝ ██║
# ╚██████╗╚██████╔╝██████╔╝███████╗██║     ██║
#  ╚═════╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝     ╚═╝
#
#  Raspberry Pi 5 × iPad Pro — UNINSTALL Script
#  --------------------------------------------------------
#  Author : av1155 (https://github.com/av1155)
#  Version: 1.0.0
# =============================================================================

set -euo pipefail

# ─── Color & Style Palette ────────────────────────────────────────────────────
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
ITALIC='\033[3m'

BLACK='\033[30m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
MAGENTA='\033[35m'
CYAN='\033[36m'
WHITE='\033[37m'

BG_BLACK='\033[40m'
BG_RED='\033[41m'
BG_GREEN='\033[42m'
BG_YELLOW='\033[43m'
BG_BLUE='\033[44m'
BG_MAGENTA='\033[45m'
BG_CYAN='\033[46m'
BG_WHITE='\033[47m'

BRIGHT_RED='\033[91m'
BRIGHT_GREEN='\033[92m'
BRIGHT_YELLOW='\033[93m'
BRIGHT_BLUE='\033[94m'
BRIGHT_MAGENTA='\033[95m'
BRIGHT_CYAN='\033[96m'
BRIGHT_WHITE='\033[97m'

# ─── Terminal Width ────────────────────────────────────────────────────────────
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
[[ $TERM_WIDTH -lt 60 ]] && TERM_WIDTH=60
[[ $TERM_WIDTH -gt 120 ]] && TERM_WIDTH=120

# ─── Log File ─────────────────────────────────────────────────────────────────
LOG_FILE="$HOME/codepi-uninstall.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ─── Utility: Print centered text ─────────────────────────────────────────────
center() {
    local text="$1"
    local color="${2:-}"
    local clean="${text//$'\033'[*m/}"  # strip ANSI for width calc
    clean=$(echo -e "$clean" | sed 's/\x1b\[[0-9;]*m//g')
    local pad=$(( (TERM_WIDTH - ${#clean}) / 2 ))
    [[ $pad -lt 0 ]] && pad=0
    printf "%${pad}s" ""
    echo -e "${color}${text}${RESET}"
}

# ─── Utility: Horizontal rule ─────────────────────────────────────────────────
hr() {
    local char="${1:-─}"
    local color="${2:-$DIM$CYAN}"
    local line=""
    for (( i=0; i<TERM_WIDTH; i++ )); do line+="$char"; done
    echo -e "${color}${line}${RESET}"
}

# ─── Utility: Box ─────────────────────────────────────────────────────────────
box() {
    local title="$1"
    local color="${2:-$CYAN}"
    local inner=$(( TERM_WIDTH - 4 ))
    local title_clean=$(echo -e "$title" | sed 's/\x1b\[[0-9;]*m//g')
    local title_pad=$(( (inner - ${#title_clean}) / 2 ))
    [[ $title_pad -lt 0 ]] && title_pad=0

    echo -e "${color}╔$(printf '═%.0s' $(seq 1 $((TERM_WIDTH-2))))╗${RESET}"
    echo -e "${color}║${RESET}$(printf ' %.0s' $(seq 1 $title_pad))${BOLD}${title}${RESET}$(printf ' %.0s' $(seq 1 $(( inner - title_pad - ${#title_clean} + 2 ))))${color}║${RESET}"
    echo -e "${color}╚$(printf '═%.0s' $(seq 1 $((TERM_WIDTH-2))))╝${RESET}"
}

# ─── Utility: Section header ──────────────────────────────────────────────────
section() {
    local num="$1"
    local title="$2"
    echo ""
    echo -e "${BOLD}${BG_RED}${WHITE} STEP ${num} ${RESET}${BOLD}${RED} ${title} ${RESET}"
    hr "─" "$DIM$RED"
}

# ─── Utility: Status messages ─────────────────────────────────────────────────
info()    { echo -e "  ${BRIGHT_CYAN}${BOLD}ℹ${RESET}  ${WHITE}$*${RESET}"; }
success() { echo -e "  ${BRIGHT_GREEN}${BOLD}✔${RESET}  ${BRIGHT_GREEN}$*${RESET}"; }
warn()    { echo -e "  ${BRIGHT_YELLOW}${BOLD}⚠${RESET}  ${BRIGHT_YELLOW}$*${RESET}"; }
error()   { echo -e "  ${BRIGHT_RED}${BOLD}✘${RESET}  ${BRIGHT_RED}$*${RESET}"; }
step()    { echo -e "  ${MAGENTA}${BOLD}→${RESET}  ${WHITE}$*${RESET}"; }
skip()    { echo -e "  ${DIM}${BOLD}–${RESET}  ${DIM}Skipped: $*${RESET}"; }

# ─── Utility: Prompt yes/no ───────────────────────────────────────────────────
ask() {
    local prompt="$1"
    local default="${2:-y}"
    local yn_hint
    [[ $default == "y" ]] && yn_hint="${BRIGHT_GREEN}Y${RESET}${DIM}/n${RESET}" || yn_hint="${DIM}y/${RESET}${BRIGHT_RED}N${RESET}"
    echo -e ""
    echo -ne "  ${BRIGHT_YELLOW}${BOLD}?${RESET}  ${BOLD}${prompt}${RESET} [${yn_hint}] "
    read -r reply
    reply="${reply:-$default}"
    [[ $reply =~ ^[Yy] ]]
}

# ─── Utility: Run a command with spinner ──────────────────────────────────────
run_spin() {
    local label="$1"
    shift
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    local pid

    echo -ne "  ${BRIGHT_CYAN}${frames[0]}${RESET}  ${label} …"

    ("$@" >> "$LOG_FILE" 2>&1) &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        echo -ne "\r  ${BRIGHT_CYAN}${frames[$i % ${#frames[@]}]}${RESET}  ${label} …"
        i=$(( i + 1 ))
        sleep 0.1
    done

    wait "$pid"
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo -e "\r  ${BRIGHT_GREEN}${BOLD}✔${RESET}  ${label}${RESET}          "
    else
        echo -e "\r  ${BRIGHT_RED}${BOLD}✘${RESET}  ${label} ${DIM}(see $LOG_FILE)${RESET}"
        return $exit_code
    fi
}

# ─── Utility: Run a command silently (no spinner, just logging) ───────────────
run_silent() {
    "$@" >> "$LOG_FILE" 2>&1
}

# ─── Splash Screen ────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${BRIGHT_RED}${BOLD}"
center "  ██████╗ ██████╗ ██████╗ ███████╗██████╗ ██╗  "
center " ██╔════╝██╔═══██╗██╔══██╗██╔════╝██╔══██╗██║  "
center " ██║     ██║   ██║██║  ██║█████╗  ██████╔╝██║  "
center " ██║     ██║   ██║██║  ██║██╔══╝  ██╔═══╝ ██║  "
center " ╚██████╗╚██████╔╝██████╔╝███████╗██║     ██║  "
center "  ╚═════╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝     ╚═╝  "
echo -e "${RESET}"
echo ""
center "Raspberry Pi 5 × iPad Pro  —  Development Environment UNINSTALL" "$BOLD$WHITE"
center "Removing USB-C Ethernet · SSH · VNC · Code-Server · and more" "$DIM$RED"
echo ""
hr "═" "$DIM$RED"
echo ""
center "Log file: ${LOG_FILE}" "$DIM"
echo ""
echo -e "  ${DIM}This script will guide you through removing each component.${RESET}"
echo -e "  ${DIM}You will be asked before each major component is uninstalled.${RESET}"
echo -e "  ${DIM}Steps that modify system files require${RESET} ${BRIGHT_YELLOW}sudo privileges${RESET}${DIM}.${RESET}"
echo ""

if ! ask "Ready to begin UNINSTALL?" "n"; then
    echo ""
    warn "Uninstall cancelled by user."
    exit 0
fi

# ─── Preflight: sudo check ────────────────────────────────────────────────────
echo ""
info "Verifying sudo access …"
if ! sudo -v; then
    error "sudo access is required. Please run as a user with sudo privileges."
    exit 1
fi
success "sudo access confirmed."

# Keep sudo alive throughout the script
( while true; do sudo -v; sleep 50; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; echo ""' EXIT

# ─── OS & Hardware Detection ──────────────────────────────────────────────────
IS_BOOKWORM=false
IS_RPI5=false
USING_NM=false

[[ $(grep -c "12 (bookworm)" /etc/os-release) -gt 0 ]] && IS_BOOKWORM=true
[[ $(grep -c "Raspberry Pi 5" /proc/device-tree/model 2>/dev/null) -gt 0 ]] && IS_RPI5=true
[[ $(systemctl is-active NetworkManager) == "active" ]] && USING_NM=true

info "Environment: RPI5=$IS_RPI5 | Bookworm=$IS_BOOKWORM | NetworkManager=$USING_NM"

# ─── STEP 1: USB0 Ethernet Reversal ──────────────────────────────────────────
section "1" "USB0 Ethernet Removal"

if ask "Remove USB0 Ethernet configuration?" "y"; then
    # ── config.txt ──────────────────────────────────────────────────────────
    step "Restoring config.txt …"
    CONFIG_TXT="/boot/firmware/config.txt"
    [[ ! -d "/boot/firmware" ]] && CONFIG_TXT="/boot/config.txt"
    if grep -q "dtoverlay=dwc2,dr_mode=peripheral" "$CONFIG_TXT" 2>/dev/null; then
        sudo sed -i '/dtoverlay=dwc2,dr_mode=peripheral/d' "$CONFIG_TXT"
        success "dtoverlay removed from config.txt"
    fi

    # ── cmdline.txt ─────────────────────────────────────────────────────────
    step "Restoring cmdline.txt …"
    CMDLINE_TXT="/boot/firmware/cmdline.txt"
    [[ ! -d "/boot/firmware" ]] && CMDLINE_TXT="/boot/cmdline.txt"
    if grep -q "modules-load=dwc2,g_ether" "$CMDLINE_TXT" 2>/dev/null; then
        sudo sed -i 's/modules-load=dwc2,g_ether //' "$CMDLINE_TXT"
        success "modules-load removed from cmdline.txt"
    fi

    # ── USB0 IP Configuration ───────────────────────────────────────────────
    if $USING_NM; then
        step "Removing NetworkManager usb0 connection …"
        if nmcli con show usb0 >/dev/null 2>&1; then
            sudo nmcli con delete usb0
            success "Removed usb0 connection via NetworkManager"
        fi
    else
        step "Removing /etc/network/interfaces.d/usb0 …"
        sudo rm -f /etc/network/interfaces.d/usb0
        
        step "Restoring /etc/dhcpcd.conf …"
        if [[ -f /etc/dhcpcd.conf ]]; then
            sudo sed -i '/interface usb0/,+5d' /etc/dhcpcd.conf
            success "usb0 config removed from dhcpcd.conf"
        fi
    fi

    # ── dnsmasq ─────────────────────────────────────────────────────────────
    step "Removing dnsmasq usb0 config …"
    sudo rm -f /etc/dnsmasq.d/usb0
    if ask "Uninstall dnsmasq package?" "n"; then
        run_spin "apt purge dnsmasq" sudo apt purge -y dnsmasq
    fi

    success "USB0 Ethernet configuration removed."
else
    skip "USB0 Ethernet removal"
fi

# ─── STEP 2: Node.js Removal ──────────────────────────────────────────────────
section "2" "Node.js Removal"

if ask "Uninstall Node.js?" "n"; then
    run_spin "Uninstalling nodejs" sudo apt-get purge -y nodejs
    run_spin "apt autoremove" sudo apt-get autoremove -y
    success "Node.js uninstalled."
else
    skip "Node.js removal"
fi

# ─── STEP 3: Code-Server Removal ──────────────────────────────────────────────
section "3" "Code-Server Removal"

if ask "Uninstall code-server?" "y"; then
    run_spin "Stopping code-server" systemctl --user stop code-server || true
    run_spin "Disabling code-server" systemctl --user disable code-server || true
    run_spin "Uninstalling code-server" bash -c 'curl -fsSL https://code-server.dev/install.sh | sh -s -- --uninstall' || true
    run_spin "Removing config" rm -rf ~/.config/code-server
    success "code-server uninstalled."
else
    skip "code-server removal"
fi

# ─── STEP 4: VNC Reversal ─────────────────────────────────────────────────────
section "4" "VNC Reversal"

if ask "Disable VNC services?" "y"; then
    if $IS_RPI5 || $IS_BOOKWORM; then
        run_spin "Stopping wayvnc" sudo systemctl stop wayvnc.service || true
        run_spin "Disabling wayvnc" sudo systemctl disable wayvnc.service || true
        success "WayVNC disabled."
    else
        run_spin "Stopping RealVNC" sudo systemctl stop vncserver-x11-serviced.service || true
        run_spin "Disabling RealVNC" sudo systemctl disable vncserver-x11-serviced.service || true
        success "RealVNC disabled."
    fi
else
    skip "VNC reversal"
fi

# ─── STEP 5: ZSH Reversal ─────────────────────────────────────────────────────
section "5" "ZSH & Oh My Zsh Removal"

if ask "Remove ZSH and Oh My Zsh?" "n"; then
    step "Restoring default shell to bash …"
    sudo chsh -s "$(which bash)" "$USER"
    
    run_spin "Removing Oh My Zsh" rm -rf ~/.oh-my-zsh
    run_spin "Removing .zshrc" rm -f ~/.zshrc
    
    if ask "Uninstall zsh package?" "n"; then
        run_spin "apt purge zsh" sudo apt purge -y zsh
    fi
    success "ZSH environment removed."
else
    skip "ZSH removal"
fi

# ─── STEP 6: Cockpit Removal ──────────────────────────────────────────────────
section "6" "Cockpit Removal"

if ask "Uninstall Cockpit?" "n"; then
    run_spin "Stopping cockpit" sudo systemctl stop cockpit.socket cockpit.service || true
    run_spin "Uninstalling cockpit" sudo apt purge -y cockpit cockpit-navigator
    success "Cockpit uninstalled."
else
    skip "Cockpit removal"
fi

# ─── STEP 7: Firewalld Removal ────────────────────────────────────────────────
section "7" "Firewalld Removal"

if ask "Uninstall Firewalld?" "n"; then
    run_spin "Stopping firewalld" sudo systemctl stop firewalld || true
    run_spin "Uninstalling firewalld" sudo apt purge -y firewalld
    success "Firewalld uninstalled."
else
    skip "Firewalld removal"
fi

# ─── STEP 8: Lazygit Removal ──────────────────────────────────────────────────
section "8" "Lazygit Removal"

if ask "Remove Lazygit?" "y"; then
    sudo rm -f /usr/local/bin/lazygit
    success "Lazygit removed."
else
    skip "Lazygit removal"
fi

# ─── STEP 9: Neovim Removal ───────────────────────────────────────────────────
section "9" "Neovim Removal"

if ask "Uninstall Neovim (Snap)?" "n"; then
    run_spin "Uninstalling nvim" sudo snap remove nvim
    success "Neovim uninstalled."
else
    skip "Neovim removal"
fi

# ─── STEP 10: Docker Removal ──────────────────────────────────────────────────
section "10" "Docker Removal"

if ask "Uninstall Docker?" "n"; then
    run_spin "Stopping docker" sudo systemctl stop docker || true
    run_spin "Uninstalling docker.io" sudo apt purge -y docker.io
    success "Docker uninstalled."
else
    skip "Docker removal"
fi

# ─── STEP 11: Java Removal ────────────────────────────────────────────────────
section "11" "Java JDK Removal"

if ask "Remove Java JDK?" "n"; then
    JDK_DIR=$(ls -d /usr/lib/jvm/jdk-22* 2>/dev/null | head -1)
    if [[ -n "$JDK_DIR" ]]; then
        sudo rm -rf "$JDK_DIR"
    fi
    
    step "Cleaning ~/.zshrc and ~/.bashrc …"
    for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
        if [[ -f "$RC" ]]; then
            sed -i '/JAVA_HOME/d' "$RC"
            sed -i '/$JAVA_HOME\/bin/d' "$RC"
        fi
    done
    success "Java JDK removed."
else
    skip "Java removal"
fi

# ─── STEP 12: Miniforge Removal ───────────────────────────────────────────────
section "12" "Miniforge Removal"

if ask "Remove Miniforge?" "n"; then
    rm -rf "$HOME/miniforge3"
    success "Miniforge removed."
else
    skip "Miniforge removal"
fi

# ─── STEP 13: TMUX Reversal ───────────────────────────────────────────────────
section "13" "TMUX & TPM Removal"

if ask "Remove TMUX configuration?" "n"; then
    rm -rf ~/.tmux
    rm -rf ~/.config/tmux
    if ask "Uninstall tmux package?" "n"; then
        run_spin "apt purge tmux" sudo apt purge -y tmux
    fi
    success "TMUX environment removed."
else
    skip "TMUX removal"
fi

# ─── STEP 14: Ruby Reversal ───────────────────────────────────────────────────
section "14" "Ruby & Colorls Removal"

if ask "Uninstall Ruby and Colorls?" "n"; then
    run_spin "Uninstalling colorls gem" gem uninstall colorls || true
    run_spin "Uninstalling ruby-full" sudo apt purge -y ruby-full
    success "Ruby environment removed."
else
    skip "Ruby removal"
fi

# ─── STEP 15: Rust Reversal ───────────────────────────────────────────────────
section "15" "Rust & Cargo Removal"

if ask "Uninstall Rust and Cargo tools?" "n"; then
    if command -v rustup &>/dev/null; then
        run_spin "Uninstalling Rust via rustup" rustup self uninstall -y
    fi
    sudo rm -f /usr/local/bin/fd
    success "Rust and Cargo tools removed."
else
    skip "Rust removal"
fi

# ─── STEP 16: LuaRocks Removal ───────────────────────────────────────────────
section "16" "LuaRocks Removal"

if ask "Uninstall LuaRocks?" "n"; then
    run_spin "Uninstalling luarocks" sudo apt purge -y luarocks
    success "LuaRocks uninstalled."
else
    skip "LuaRocks removal"
fi

# ─── STEP 17: MOTD Restoration ───────────────────────────────────────────────
section "17" "Restore MOTD"

if ask "Restore MOTD?" "y"; then
    if [[ -f /etc/motdDisabled ]]; then
        sudo mv /etc/motdDisabled /etc/motd
        success "MOTD restored."
    else
        info "MOTD backup not found."
    fi
else
    skip "MOTD restoration"
fi

# ─── STEP 18: Optional Packages Removal ──────────────────────────────────────
section "18" "Optional APT Packages (delta, thefuck) Removal"

if ask "Uninstall optional packages (delta, thefuck)?" "n"; then
    run_spin "Uninstalling delta" sudo apt purge -y delta || true
    run_spin "Uninstalling thefuck" sudo apt purge -y thefuck || true
    success "Optional packages uninstalled."
else
    skip "Optional packages removal"
fi

# ─── FINAL SUMMARY ───────────────────────────────────────────────────────────
echo ""
hr "═" "$BRIGHT_RED"
center "  UNINSTALL COMPLETE  " "$BRIGHT_RED"
hr "═" "$BRIGHT_RED"
echo ""
warn "A system reboot is recommended to apply all network and shell changes."
echo ""

if ask "Reboot now?" "n"; then
    sudo reboot
else
    success "All done! Reboot when you're ready."
fi
