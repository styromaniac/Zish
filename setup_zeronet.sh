#!/data/data/com.termux/files/usr/bin/bash

set -e

ZERONET_DIR="$HOME/apps/zeronet"
LOG_FILE="$HOME/zeronet_install.log"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    log "[ERROR] $1"
    exit 1
}

setup_venv() {
    log "Setting up Python virtual environment..."
    python -m venv "$ZERONET_DIR/venv" || log_error "Failed to create virtual environment"
    source "$ZERONET_DIR/venv/bin/activate" || log_error "Failed to activate virtual environment"
    pip install --upgrade pip setuptools wheel || log_error "Failed to upgrade pip, setuptools, and wheel"
}

clone_zeronet() {
    log "Cloning ZeroNet repository..."
    git clone https://github.com/HelloZeroNet/ZeroNet.git "$ZERONET_DIR" || log_error "Failed to clone ZeroNet repository"
    cd "$ZERONET_DIR" || log_error "Failed to change to ZeroNet directory"
}

install_dependencies() {
    log "Installing dependencies..."
    export LIBRARY_PATH=$PREFIX/lib
    export C_INCLUDE_PATH=$PREFIX/include
    export LD_LIBRARY_PATH=$PREFIX/lib
    export LIBSECP256K1_STATIC=1

    pip uninstall -y coincurve
    pip cache purge

    pkg install -y autoconf automake libtool

    pip install gevent pycryptodome || log_error "Failed to install gevent and pycryptodome"

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
        exit 1
    fi

    log "coincurve installed successfully"
    python -c "import pkg_resources; print(f'coincurve version: {pkg_resources.get_distribution(\"coincurve\").version}')"

    cd ~
    rm -rf libsecp256k1
}

install_requirements() {
    log "Installing ZeroNet requirements..."
    if [ -f requirements.txt ]; then
        pip install -r requirements.txt || log_error "Failed to install ZeroNet requirements"
    else
        log_error "requirements.txt not found"
    fi
}

generate_initial_zeronet_conf() {
    log "Generating initial ZeroNet configuration..."
    cat > "$ZERONET_DIR/zeronet.conf" << EOL
[global]
data_dir = $ZERONET_DIR/data
log_dir = $HOME/.zeronet_logs
ui_ip = 127.0.0.1
ui_port = 43110
tor_controller = 127.0.0.1:49051
tor_proxy = 127.0.0.1:49050
trackers_file = $ZERONET_DIR/trackers.json
use_openssl = True
disable_udp = True
fileserver_ip_type = ipv4
language = en
tor = always
EOL
}

main() {
    if [ -d "$ZERONET_DIR" ]; then
        log "ZeroNet directory already exists. Removing it..."
        rm -rf "$ZERONET_DIR"
    fi

    mkdir -p "$ZERONET_DIR"
    
    setup_venv
    clone_zeronet
    install_dependencies
    install_requirements
    generate_initial_zeronet_conf

    log "ZeroNet setup completed successfully."
}

main
