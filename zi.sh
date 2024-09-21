#!/data/data/com.termux/files/usr/bin/bash

set -e

ZERONET_DIR="$HOME/apps/zeronet"
LOG_FILE="$HOME/zeronet_install.log"
TORRC_FILE="$HOME/.tor/torrc"

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to log errors and exit
log_error() {
    log "[ERROR] $1"
    exit 1
}

termux-wake-lock

termux-change-repo

termux-setup-storage

# Function to update package mirrors
update_mirrors() {
    local max_attempts=5
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if pkg update; then
            log "Successfully updated package lists"
            return 0
        else
            log "Failed to update package lists. Attempt $attempt of $max_attempts."
            if [ $attempt -lt $max_attempts ]; then
                log "Trying a different mirror..."
                termux-change-repo
                sleep 5
            fi
            ((attempt++))
        fi
    done
    log_error "Failed to update package lists after $max_attempts attempts."
    return 1
}

update_mirrors || exit 1

pkg upgrade -y

# Install required packages
required_packages=(
    termux-tools termux-keyring
    netcat-openbsd binutils git cmake libffi
    curl unzip libtool automake autoconf pkg-config findutils
    clang make termux-api tor perl
    rust openssl openssl-tool wget build-essential
    zlib libbz2 liblzma libsqlite
)
install_package() {
    local package=$1
    local max_attempts=3
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if pkg install -y "$package"; then
            log "Successfully installed $package"
            return 0
        else
            log "Failed to install $package. Attempt $attempt of $max_attempts."
            if [ $attempt -lt $max_attempts ]; then
                log "Retrying in 5 seconds..."
                sleep 5
            fi
            ((attempt++))
        fi
    done
    log_error "Failed to install $package after $max_attempts attempts."
    return 1
}

for package in "${required_packages[@]}"; do
    if ! dpkg -s "$package" >/dev/null 2>&1; then
        install_package "$package" || exit 1
    fi
done

log "Using OpenSSL provided by Termux"

# Ensure environment variables are correctly set
export CFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"
export LD_LIBRARY_PATH="$PREFIX/lib"

# Compile Python 3.10 from source
log "Downloading and compiling Python 3.10.13 from source..."
cd $HOME
wget https://www.python.org/ftp/python/3.10.13/Python-3.10.13.tgz
tar -xf Python-3.10.13.tgz
cd Python-3.10.13

./configure --prefix=$PREFIX --enable-shared --enable-optimizations --with-ensurepip=install
make -j$(nproc)
make install

# Verify Python 3.10 installation
if ! command -v python3.10 &> /dev/null; then
    log_error "Python 3.10 installation failed."
fi
log "Python 3.10 installed successfully."

# Clean up Python source files
cd $HOME
rm -rf Python-3.10.13*
export PATH="$PREFIX/bin:$PATH"

# Prompt user for ZeroNet source URL
log "Please enter the ZeroNet source URL you wish to use (Git repository, .zip, or .tar.gz):"
read -r ZERONET_SOURCE_URL
ZERONET_SOURCE_URL=${ZERONET_SOURCE_URL:-https://github.com/HelloZeroNet/ZeroNet.git}

# Determine the source type
if [[ $ZERONET_SOURCE_URL == *.git ]]; then
    SOURCE_TYPE="git"
elif [[ $ZERONET_SOURCE_URL == *.zip ]]; then
    SOURCE_TYPE="zip"
elif [[ $ZERONET_SOURCE_URL == *.tar.gz ]]; then
    SOURCE_TYPE="tar.gz"
else
    log_error "Unsupported ZeroNet source URL format."
fi

# Prompt user for ZeroNet branch or tag (Git only)
if [ "$SOURCE_TYPE" == "git" ]; then
    log "Enter the branch or tag you wish to checkout (leave blank for default branch):"
    read -r ZERONET_BRANCH
fi

# Create ZeroNet directory
if [ -d "$ZERONET_DIR" ] && [ "$(ls -A "$ZERONET_DIR")" ]; then
    log "The directory $ZERONET_DIR already exists and is not empty."
    log "Proceeding to adjust permissions and clean the directory."
    chmod -R u+rwX "$ZERONET_DIR" || { log_error "Failed to adjust permissions on existing directory"; exit 1; }
    rm -rf "$ZERONET_DIR" || { log_error "Failed to remove existing directory"; exit 1; }
fi

mkdir -p "$ZERONET_DIR"

# Download and extract ZeroNet based on source type
cd "$ZERONET_DIR"

if [ "$SOURCE_TYPE" == "git" ]; then
    # Clone ZeroNet repository
    log "Cloning ZeroNet repository from $ZERONET_SOURCE_URL..."
    git clone "$ZERONET_SOURCE_URL" . || { log_error "Failed to clone ZeroNet repository"; exit 1; }
    # Checkout the specified branch or tag if provided
    if [ -n "$ZERONET_BRANCH" ]; then
        log "Checking out branch/tag: $ZERONET_BRANCH"
        git checkout "$ZERONET_BRANCH" || { log_error "Failed to checkout branch/tag $ZERONET_BRANCH"; exit 1; }
    fi
elif [ "$SOURCE_TYPE" == "zip" ]; then
    # Download and extract zip file
    log "Downloading ZeroNet zip archive..."
    wget -O zeronet.zip "$ZERONET_SOURCE_URL" || { log_error "Failed to download ZeroNet zip archive"; exit 1; }
    unzip zeronet.zip || { log_error "Failed to extract ZeroNet zip archive"; exit 1; }
    # Move contents to ZERONET_DIR
    mv ZeroNet-*/* . || { log_error "Failed to move ZeroNet files"; exit 1; }
    rm -rf ZeroNet-* zeronet.zip
elif [ "$SOURCE_TYPE" == "tar.gz" ]; then
    # Download and extract tar.gz file
    log "Downloading ZeroNet tar.gz archive..."
    wget -O zeronet.tar.gz "$ZERONET_SOURCE_URL" || { log_error "Failed to download ZeroNet tar.gz archive"; exit 1; }
    tar -xzf zeronet.tar.gz || { log_error "Failed to extract ZeroNet tar.gz archive"; exit 1; }
    # Move contents to ZERONET_DIR
    mv ZeroNet-*/* . || { log_error "Failed to move ZeroNet files"; exit 1; }
    rm -rf ZeroNet-* zeronet.tar.gz
fi

if [ ! -f "zeronet.py" ]; then
    log_error "zeronet.py not found in the expected directory."
    exit 1
fi

# Create virtual environment with Python 3.10
log "Creating virtual environment with Python 3.10..."
python3.10 -m venv venv

source "$ZERONET_DIR/venv/bin/activate"

log "Installing required Python packages..."
pip install --upgrade pip setuptools wheel

pip install gevent pycryptodome cryptography pyOpenSSL coincurve

# Verify installations
log "Verifying installations..."
python -c "import gevent; import Crypto; import cryptography; import OpenSSL; import coincurve; print('All required Python packages successfully installed')" || log_error "Failed to import one or more required Python packages"

chmod -R u+rwX "$ZERONET_DIR"

# Create data directory
mkdir -p ./data
chmod -R u+rwX ./data

mkdir -p /data/data/com.termux/files/usr/var/log/

update_trackers() {
    log "Updating trackers list..."
    TRACKERS_FILE="$ZERONET_DIR/data/trackers.json"
    trackers_url="https://trackerslist.com/best_aria2.txt"
    mkdir -p "$(dirname "$TRACKERS_FILE")"

    if curl -s -f "$trackers_url" -o "$TRACKERS_FILE"; then
        log "Successfully downloaded tracker list from $trackers_url"
    else
        log_error "Failed to download tracker list from $trackers_url."
    fi

    # Ensure trackers.json is not empty
    if [ ! -s "$TRACKERS_FILE" ]; then
        log_error "Trackers list is empty after download."
    fi
}

create_zeronet_conf() {
    local conf_file="$ZERONET_DIR/zeronet.conf"

    cat > "$conf_file" << EOL
[global]
data_dir = $ZERONET_DIR/data
log_dir = /data/data/com.termux/files/usr/var/log/zeronet
ui_ip = 127.0.0.1
ui_port = 43110
tor_controller = 127.0.0.1:49051
tor_proxy = 127.0.0.1:49050
trackers_file = $ZERONET_DIR/data/trackers.json
language = en
tor = always
EOL
    log "ZeroNet configuration file created at $conf_file with security settings"
}

get_zeronet_port() {
    log "Starting ZeroNet briefly to generate config..."
    cd $ZERONET_DIR && . ./venv/bin/activate
    python zeronet.py --config_file $ZERONET_DIR/zeronet.conf > zeronet_output.log 2>&1 &
    TEMP_ZERONET_PID=$!

    # Wait until zeronet.conf is updated with fileserver_port or timeout after 60 seconds
    timeout=60
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if grep -q 'fileserver_port' "$ZERONET_DIR/zeronet.conf"; then
            break
        fi
        sleep 1
        elapsed=$((elapsed+1))
    done

    if ! grep -q 'fileserver_port' "$ZERONET_DIR/zeronet.conf"; then
        kill $TEMP_ZERONET_PID
        log_error "zeronet.conf was not updated with fileserver_port after $timeout seconds."
        exit 1
    fi

    FILESERVER_PORT=$(grep -oP '(?<=fileserver_port = )\d+' "$ZERONET_DIR/zeronet.conf")
    if [ -z "$FILESERVER_PORT" ]; then
        kill $TEMP_ZERONET_PID
        log_error "Failed to determine ZeroNet's file server port"
        exit 1
    fi
    log "ZeroNet chose port: $FILESERVER_PORT"
    kill $TEMP_ZERONET_PID
    rm zeronet_output.log
}

configure_tor() {
    log "Configuring Tor..."
    mkdir -p $HOME/.tor
    mkdir -p /data/data/com.termux/files/usr/var/log/tor
    mkdir -p /data/data/com.termux/files/home/.tor/ZeroNet

    cat > $HOME/.tor/torrc << EOL
SocksPort 49050
ControlPort 49051
CookieAuthentication 1
HiddenServiceDir /data/data/com.termux/files/home/.tor/ZeroNet
HiddenServicePort 80 127.0.0.1:$FILESERVER_PORT
HiddenServiceVersion 3
Log notice file /data/data/com.termux/files/usr/var/log/tor/notices.log
EOL
    log "Tor configuration created at $HOME/.tor/torrc"
}

update_trackers
create_zeronet_conf
get_zeronet_port
configure_tor

log "Starting Tor service..."
tor -f $HOME/.tor/torrc &
TOR_PID=$!

log "Waiting for Tor to start and generate the hidden service..."
sleep 30

if kill -0 $TOR_PID 2>/dev/null; then
    log "Tor process is still running after 30 seconds. Proceeding with hidden service setup."
else
    log_error "Tor process is not running. There may have been an issue starting Tor."
    exit 1
fi

log "Retrieving onion address..."
if [ -f "/data/data/com.termux/files/home/.tor/ZeroNet/hostname" ]; then
    ONION_ADDRESS=$(cat /data/data/com.termux/files/home/.tor/ZeroNet/hostname)
    log "Onion address: $ONION_ADDRESS"
else
    log_error "Failed to retrieve onion address. Tor hidden service may not have been created properly."
    log "Contents of the hidden service directory:"
    ls -la /data/data/com.termux/files/home/.tor/ZeroNet
    log "Last 20 lines of Tor log:"
    tail -n 20 /data/data/com.termux/files/usr/var/log/tor/notices.log
    exit 1
fi

BOOT_SCRIPT="$HOME/.termux/boot/start-zeronet"
mkdir -p "$HOME/.termux/boot"

log "This script will create a Termux Boot script at: $BOOT_SCRIPT"
log "The script will start ZeroNet automatically when your device boots."
log ""
log "IMPORTANT: For this to work, you need to have opened Termux:Boot at least once since the last fresh start of Termux."
log ""
log "Have you done this? (y/n)"
read -r boot_setup

if [[ $boot_setup =~ ^[Yy]$ ]]; then
    cat > "$BOOT_SCRIPT" << EOL
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock

ZERONET_DIR=$ZERONET_DIR
TORRC_FILE=$HOME/.tor/torrc

start_tor() {
    tor -f "\$TORRC_FILE" &
    sleep 30
}

start_zeronet() {
    cd "\$ZERONET_DIR"
    source ./venv/bin/activate
    python zeronet.py --config_file "\$ZERONET_DIR/zeronet.conf" &

    ZERONET_PID=\$!
    echo "ZeroNet started with PID \$ZERONET_PID"
    termux-notification --title "ZeroNet Running" --content "ZeroNet started with PID \$ZERONET_PID" --ongoing
}

start_tor
start_zeronet
EOL

    chmod +x "$BOOT_SCRIPT"
    log "Termux Boot script created at $BOOT_SCRIPT"
else
    log "Please open Termux:Boot once since the last fresh start of Termux, then run this script again to set up auto-start."
fi

start_zeronet() {
    cd $ZERONET_DIR
    source ./venv/bin/activate

    if [ -d "$ZERONET_DIR/plugins/disabled-Bootstrapper" ]; then
        mv "$ZERONET_DIR/plugins/disabled-Bootstrapper" "$ZERONET_DIR/plugins/Bootstrapper"
        log "Renamed disabled-Bootstrapper to Bootstrapper"
    else
        log "disabled-Bootstrapper directory not found"
    fi

    python zeronet.py --config_file $ZERONET_DIR/zeronet.conf &
    ZERONET_PID=$!
    log "ZeroNet started with PID $ZERONET_PID"
    termux-notification --title "ZeroNet Running" --content "ZeroNet started with PID $ZERONET_PID" --ongoing
}

log "Starting ZeroNet..."
start_zeronet

if ! ps -p $ZERONET_PID > /dev/null; then
    log_error "Failed to start ZeroNet"
    termux-notification --title "ZeroNet Error" --content "Failed to start ZeroNet"
    exit 1
fi

log "ZeroNet is running. You can access it at http://127.0.0.1:43110"

view_log() {
    termux-dialog confirm -i "View last 50 lines of log?" -t "View Log"
    if [ $? -eq 0 ]; then
        LOG_CONTENT=$(tail -n 50 "/data/data/com.termux/files/usr/var/log/zeronet/debug.log")
        termux-dialog text -t "ZeroNet Log (last 50 lines)" -i "$LOG_CONTENT"
    fi
}

restart_zeronet() {
    termux-dialog confirm -i "Are you sure you want to restart ZeroNet?" -t "Restart ZeroNet"
    if [ $? -eq 0 ]; then
        log "Restarting ZeroNet..."
        kill $ZERONET_PID
        start_zeronet
        log "ZeroNet restarted with PID $ZERONET_PID"
        termux-notification --title "ZeroNet Restarted" --content "New PID: $ZERONET_PID"
    fi
}

LAST_CHECKED_TIME=0
HOMEPAGE_ADDRESS="1HeLLo4uzjaLetFx6NH3PMwFP3qbRbTf3D"  # ZeroNet's default home page

check_for_new_content() {
    local content_json="$ZERONET_DIR/data/$HOMEPAGE_ADDRESS/content.json"
    if [ ! -f "$content_json" ]; then
        log "content.json not found for ZeroNet homepage. Skipping check."
        return
    fi

    local current_time=$(date +%s)
    local file_mod_time=$(stat -c %Y "$content_json")

    if [ $file_mod_time -gt $LAST_CHECKED_TIME ]; then
        log "New content detected on ZeroNet homepage."
        termux-notification --title "New ZeroNet Content" --content "New content detected on ZeroNet homepage."
        LAST_CHECKED_TIME=$current_time
    else
        log "No new content detected on ZeroNet homepage."
    fi
}

check_content_loop() {
    while true; do
        check_for_new_content
        sleep 300  # Check every 5 minutes
    done
}

check_content_loop &
CONTENT_CHECK_PID=$!

while true; do
    ACTION=$(termux-dialog sheet -v "View Log,Restart ZeroNet,Check for New Content,Exit" -t "ZeroNet Management")
    case $ACTION in
        *"View Log"*)
            view_log
            ;;
        *"Restart ZeroNet"*)
            restart_zeronet
            ;;
        *"Check for New Content"*)
            check_for_new_content
            ;;
        *"Exit"*)
            termux-dialog confirm -i "Are you sure you want to exit? This will stop ZeroNet and content checking." -t "Exit ZeroNet"
            if [ $? -eq 0 ]; then
                log "Stopping ZeroNet and exiting..."
                kill $ZERONET_PID
                kill $CONTENT_CHECK_PID
                termux-notification-remove 1
                exit 0
            fi
            ;;
        *)
            termux-toast "Invalid choice. Please try again."
            ;;
    esac
done