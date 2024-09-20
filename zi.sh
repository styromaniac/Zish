#!/data/data/com.termux/files/usr/bin/bash

termux-change-repo 

termux-wake-lock

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

#========== SECTION: INSTALL PACKAGES ==========
install_packages() {
    log "Starting package installation..."
    
    log "Updating package lists and upgrading existing packages..."
    pkg update && pkg upgrade -y || log_error "Failed to update/upgrade packages"
    
    log "Installing required packages..."
    required_packages=(
        termux-tools termux-keyring python
        netcat-openbsd binutils git cmake libffi openssl
        curl unzip libtool automake autoconf pkg-config findutils
        clang make termux-api tor
    )

    for package in "${required_packages[@]}"; do
        pkg install -y "$package" || log_error "Failed to install $package"
    done

    log "Package installation completed."
}

#========== SECTION: SETUP ZERONET ==========
setup_zeronet() {
    log "Starting ZeroNet setup..."
    
    python -m venv "$ZERONET_DIR/venv" || log_error "Failed to create virtual environment"
    source "$ZERONET_DIR/venv/bin/activate" || log_error "Failed to activate virtual environment"
    pip install --upgrade pip setuptools wheel || log_error "Failed to upgrade pip, setuptools, and wheel"

    git clone https://github.com/HelloZeroNet/ZeroNet.git "$ZERONET_DIR" || log_error "Failed to clone ZeroNet repository"
    cd "$ZERONET_DIR" || log_error "Failed to change to ZeroNet directory"

    export LIBRARY_PATH=$PREFIX/lib
    export C_INCLUDE_PATH=$PREFIX/include
    export LD_LIBRARY_PATH=$PREFIX/lib
    export LIBSECP256K1_STATIC=1

    pip install gevent pycryptodome || log_error "Failed to install gevent and pycryptodome"

    pip uninstall -y coincurve
    pip cache purge

    cd ~
    git clone https://github.com/bitcoin-core/secp256k1.git libsecp256k1
    cd libsecp256k1

    ./autogen.sh
    ./configure --prefix=$PREFIX --enable-module-recovery --enable-experimental --enable-module-ecdh
    make
    make install

    cd "$ZERONET_DIR"

    CFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib -lpython3.11 -lsecp256k1" pip install --no-cache-dir --no-binary :all: coincurve

    if ! python -c "from coincurve import PrivateKey; key = PrivateKey(); print(key.public_key.format())" > /dev/null 2>&1; then
        log_error "Failed to install coincurve"
    fi

    log "coincurve installed successfully"
    python -c "import pkg_resources; print(f'coincurve version: {pkg_resources.get_distribution(\"coincurve\").version}')"

    cd ~
    rm -rf libsecp256k1

    cd "$ZERONET_DIR"
    pip install -r requirements.txt || log_error "Failed to install ZeroNet requirements"

    log "ZeroNet setup completed."
}

#========== SECTION: CONFIGURE TOR ==========
configure_tor() {
    log "Starting Tor configuration..."
    
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

    tor -f $TORRC_FILE &
    sleep 30  # Wait for Tor to bootstrap

    ONION_ADDRESS=$(cat /data/data/com.termux/files/home/.tor/ZeroNet/hostname)
    echo "ip_external = ${ONION_ADDRESS}" >> "$ZERONET_DIR/zeronet.conf"

    log "Tor configuration completed."
}

#========== SECTION: CREATE BOOT SCRIPT ==========
create_boot_script() {
    log "Creating boot script..."
    
    BOOT_SCRIPT="$HOME/.termux/boot/start-zeronet"
    mkdir -p "$(dirname "$BOOT_SCRIPT")"
    cat > "$BOOT_SCRIPT" << EOL
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock

ZERONET_DIR="$ZERONET_DIR"
TORRC_FILE="$TORRC_FILE"

start_tor() {
    tor -f "\$TORRC_FILE" &
    sleep 30
}

start_zeronet() {
    cd "\$ZERONET_DIR"
    source venv/bin/activate
    python zeronet.py --config_file zeronet.conf &
    
    ZERONET_PID=\$!
    echo "ZeroNet started with PID \$ZERONET_PID"
    termux-notification --title "ZeroNet Running" --content "ZeroNet started with PID \$ZERONET_PID" --ongoing
}

check_for_new_content() {
    LAST_CHECKED_TIME=0
    HOMEPAGE_ADDRESS="191CazMVNaAcT9Y1zhkxd9ixMBPs59g2um"

    while true; do
        content_json="\$ZERONET_DIR/data/\$HOMEPAGE_ADDRESS/content.json"
        if [ -f "\$content_json" ]; then
            current_time=\$(date +%s)
            file_mod_time=\$(stat -c %Y "\$content_json")

            if [ \$file_mod_time -gt \$LAST_CHECKED_TIME ]; then
                new_posts=\$(python -c "
import json
with open('\$content_json', 'r') as f:
    data = json.load(f)
posts = data.get('posts', [])
new_posts = [post for post in posts if post.get('date_added', 0) / 1000 > \$LAST_CHECKED_TIME]
for post in new_posts[:5]:
    print(f\"New post: {post.get('title', 'Untitled')}\")")

                if [ ! -z "\$new_posts" ]; then
                    echo "\$new_posts"
                    termux-notification --title "New ZeroNet Content" --content "\$new_posts"
                fi
                LAST_CHECKED_TIME=\$current_time
            fi
        fi
        sleep 300  # Check every 5 minutes
    done
}

start_tor
start_zeronet
check_for_new_content &
EOL

    chmod +x "$BOOT_SCRIPT"
    log "Boot script creation completed."
}

#========== MAIN EXECUTION ==========
main() {
    log "Starting ZeroNet installation process..."

    install_packages
    setup_zeronet
    configure_tor
    create_boot_script

    log "ZeroNet installation complete."
    log "You can now run '$HOME/.termux/boot/start-zeronet' to start ZeroNet manually."
    log "To enable auto-start, make sure you've opened Termux:Boot at least once since the last fresh start of Termux."
    log "Enjoy using ZeroNet!"
}

main
