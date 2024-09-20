#!/data/data/com.termux/files/usr/bin/bash

set -e

ZERONET_DIR="$HOME/apps/zeronet"
LOG_FILE="$HOME/zeronet_install.log"
TORRC_FILE="$HOME/.tor/torrc"
BOOT_SCRIPT="$HOME/.termux/boot/start-zeronet"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    log "[ERROR] $1"
    exit 1
}

create_boot_script() {
    log "Creating boot script at $BOOT_SCRIPT"
    mkdir -p "$(dirname "$BOOT_SCRIPT")"
    cat > "$BOOT_SCRIPT" << EOL
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock

ZERONET_DIR="$ZERONET_DIR"
TORRC_FILE="$TORRC_FILE"

start_tor() {
    tor -f "\$TORRC_FILE" &
    sleep 30  # Wait 30 seconds for Tor to bootstrap
}

start_zeronet() {
    cd "\$ZERONET_DIR"
    source venv/bin/activate
    python zeronet.py --config_file zeronet.conf &
    
    ZERONET_PID=\$!
    echo "ZeroNet started with PID \$ZERONET_PID"
    termux-notification --title "ZeroNet Running" --content "ZeroNet started with PID \$ZERONET_PID" --ongoing
}

start_tor
start_zeronet
EOL
    chmod +x "$BOOT_SCRIPT"
}

main() {
    create_boot_script
    log "Boot script created successfully."
    log "To enable auto-start, make sure you've opened Termux:Boot at least once since the last fresh start of Termux."
}

main
