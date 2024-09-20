#!/data/data/com.termux/files/usr/bin/bash

set -e

REPO_URL="https://github.com/styromaniac/Zish/raw/refs/heads/main"
LOG_FILE="$HOME/zeronet_install.log"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    log "[ERROR] $1"
    exit 1
}

download_and_execute() {
    local script_name=$1
    log "Downloading and executing $script_name..."
    bash <(curl -fsSL "$REPO_URL/$script_name" | sed 's/\r$//')
    if [ $? -ne 0 ]; then
        log_error "Failed to execute $script_name"
    fi
}

main() {
    log "Starting ZeroNet installation process..."

    download_and_execute "install_packages.sh"
    download_and_execute "setup_zeronet.sh"
    download_and_execute "configure_tor.sh"
    download_and_execute "create_boot_script.sh"

    log "ZeroNet installation complete. You can now run '$HOME/.termux/boot/start-zeronet' to start ZeroNet."
    log "To enable auto-start, make sure you've opened Termux:Boot at least once since the last fresh start of Termux."
}

main
