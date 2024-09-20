#!/data/data/com.termux/files/usr/bin/bash

set -e

ZERONET_DIR="$HOME/apps/zeronet"
LOG_FILE="$HOME/zeronet_install.log"
TORRC_FILE="$HOME/.tor/torrc"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    log "[ERROR] $1"
    exit 1
}

configure_tor() {
    log "Configuring Tor..."
    mkdir -p $HOME/.tor
    mkdir -p /data/data/com.termux/files/usr/var/log/tor
    mkdir -p /data/data/com.termux/files/home/.tor/ZeroNet

    cat > $TORRC_FILE << EOL
SocksPort 49050
ControlPort 49051
HiddenServiceDir /data/data/com.termux/files/home/.tor/ZeroNet
HiddenServicePort 80 127.0.0.1:43110
HiddenServiceVersion 3
Log notice file /data/data/com.termux/files/usr/var/log/tor/notices.log
EOL
    log "Tor configuration created at $TORRC_FILE"
}

start_tor() {
    log "Starting Tor service..."
    tor -f $TORRC_FILE &
    TOR_PID=$!

    log "Waiting for Tor to start and generate the hidden service..."
    sleep 30

    if kill -0 $TOR_PID 2>/dev/null; then
        log "Tor process is still running after 30 seconds. Proceeding with hidden service setup."
    else
        log_error "Tor process is not running. There may have been an issue starting Tor."
    fi
}

get_onion_address() {
    local hostname_file="/data/data/com.termux/files/home/.tor/ZeroNet/hostname"
    if [ -f "$hostname_file" ]; then
        ONION_ADDRESS=$(cat "$hostname_file")
        log "Onion address: $ONION_ADDRESS"
    else
        log_error "Failed to retrieve onion address. Tor hidden service may not have been created properly."
    fi
}

update_zeronet_config() {
    log "Updating ZeroNet configuration with onion address..."
    sed -i "s/ip_external = .*/ip_external = ${ONION_ADDRESS}/" "$ZERONET_DIR/zeronet.conf"
    log "ZeroNet configuration updated with onion address"
}

main() {
    configure_tor
    start_tor
    get_onion_address
    update_zeronet_config
    
    log "Tor configuration and startup completed successfully."
}

main
