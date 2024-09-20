#!/data/data/com.termux/files/usr/bin/bash

set -e

REPO_URL="https://raw.githubusercontent.com/styromaniac/Zish/refs/heads/main"
LOG_FILE="$HOME/zeronet_install.log"
TEMP_DIR=$(mktemp -d)

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    log "[ERROR] $1"
    exit 1
}

download_script() {
    local script_name=$1
    local full_url="$REPO_URL/$script_name"
    local output_file="$TEMP_DIR/$script_name"
    
    log "Downloading $script_name..."
    if curl -fsSL "$full_url" -o "$output_file"; then
        log "Successfully downloaded $script_name"
    else
        log_error "Failed to download $script_name. URL: $full_url"
    fi
}

execute_script() {
    local script_name=$1
    local script_path="$TEMP_DIR/$script_name"
    
    log "Executing $script_name..."
    if [ -f "$script_path" ]; then
        bash "$script_path"
        if [ $? -ne 0 ]; then
            log_error "Failed to execute $script_name"
        fi
    else
        log_error "Script file not found: $script_path"
    fi
}

main() {
    log "Starting ZeroNet installation process..."

    # Download all scripts first
    download_script "install_packages.sh"
    download_script "setup_zeronet.sh"
    download_script "configure_tor.sh"
    download_script "create_boot_script.sh"

    # Execute scripts in order
    execute_script "install_packages.sh"
    execute_script "setup_zeronet.sh"
    execute_script "configure_tor.sh"
    execute_script "create_boot_script.sh"

    # Clean up
    rm -rf "$TEMP_DIR"

    log "ZeroNet installation complete."
    log "You can now run '$HOME/.termux/boot/start-zeronet' to start ZeroNet manually."
    log "To enable auto-start, make sure you've opened Termux:Boot at least once since the last fresh start of Termux."
    log "Enjoy using ZeroNet!"
}

main
