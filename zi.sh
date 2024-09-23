#!/data/data/com.termux/files/usr/bin/bash

termux-wake-lock

termux-change-repo

termux-setup-storage

ZERONET_DIR="$HOME/apps/zeronet"
LOG_FILE="$HOME/zeronet_install.log"
TORRC_FILE="$HOME/.tor/torrc"
TOR_PROXY_PORT=49050
TOR_CONTROL_PORT=49051

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    log "[ERROR] $1"
    exit 1
}

# User prompts
log "Please provide the Git clone URL or path to the ZeroNet source code archive (Git URL, .zip, or .tar.gz):"
read -r zeronet_source

log "Please provide URL, path to users.json, or press Enter to skip:"
read -r users_json_source

BOOT_SCRIPT="$HOME/.termux/boot/start-zeronet"
log "This script will create a Termux Boot script at: $BOOT_SCRIPT"
log "The script will start ZeroNet automatically when your device boots."
log ""
log "IMPORTANT: For this to work, you need to have opened Termux:Boot at least once since the last fresh start of Termux."
log ""
log "Have you done this? (y/n)"
read -r boot_setup

update_mirrors() {
    local max_attempts=5
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if yes | pkg update; then
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

yes | pkg upgrade

required_packages=(
    termux-tools termux-keyring python
    netcat-openbsd binutils git cmake libffi
    curl unzip libtool automake autoconf pkg-config findutils
    clang make termux-api tor perl jq rust openssl-tool net-tools
)

install_package() {
    local package=$1
    local max_attempts=3
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if yes | pkg install -y "$package"; then
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

log "Installing OpenSSL from Termux repository..."
yes | pkg install -y openssl-tool || log_error "Failed to install OpenSSL from repository"

log "OpenSSL installation completed."

install_python_packages() {
    log "Installing required Python packages..."
    export CFLAGS="-I$PREFIX/include"
    export LDFLAGS="-L$PREFIX/lib"

    pip install --upgrade pip setuptools wheel

    MAX_RETRIES=3
    RETRY_DELAY=10

    install_package_with_retry() {
        local package=$1
        local retries=0
        while [ $retries -lt $MAX_RETRIES ]; do
            if pip install --no-deps $package; then
                log "Successfully installed $package"
                return 0
            else
                retries=$((retries + 1))
                log "Failed to install $package. Attempt $retries of $MAX_RETRIES."
                if [ $retries -lt $MAX_RETRIES ]; then
                    log "Retrying in $RETRY_DELAY seconds..."
                    sleep $RETRY_DELAY
                    # Kill any hanging processes
                    pkill -f "pip install"
                    # Clean up temporary directories
                    rm -rf /tmp/pip-*
                fi
            fi
        done
        log_error "Failed to install $package after $MAX_RETRIES attempts."
        return 1
    }

    # Try different installation methods
    install_package_with_fallbacks() {
        local package=$1
        if ! install_package_with_retry $package; then
            log "Attempting to install $package with binary distribution..."
            if ! pip install --only-binary=:all: $package; then
                if [ "$package" = "cryptography" ]; then
                    log "Attempting to install cryptography without Rust..."
                    if ! CRYPTOGRAPHY_DONT_BUILD_RUST=1 pip install cryptography; then
                        log_error "All installation methods failed for $package"
                        return 1
                    fi
                else
                    log_error "All installation methods failed for $package"
                    return 1
                fi
            fi
        fi
        return 0
    }

    install_package_with_fallbacks greenlet || return 1
    install_package_with_fallbacks gevent || return 1
    install_package_with_fallbacks pycryptodome || return 1
    install_package_with_fallbacks cryptography || return 1
    install_package_with_fallbacks pyOpenSSL || return 1
    install_package_with_fallbacks cffi || return 1
    install_package_with_fallbacks six || return 1
    install_package_with_fallbacks idna || return 1

    log "Verifying installations..."
    python3 -c "import gevent; import Crypto; import cryptography; import OpenSSL; print('All required Python packages successfully installed')" || log_error "Failed to import one or more required Python packages"
}

install_python_packages || exit 1

if [ -d "$ZERONET_DIR" ] && [ "$(ls -A "$ZERONET_DIR")" ]; then
    log "The directory $ZERONET_DIR already exists and is not empty."
    log "Proceeding to adjust permissions and clean the directory."
    chmod -R u+rwX "$ZERONET_DIR" || { log_error "Failed to adjust permissions on existing directory"; exit 1; }
    rm -rf "$ZERONET_DIR" || { log_error "Failed to remove existing directory"; exit 1; }
fi

mkdir -p "$ZERONET_DIR"

WORK_DIR="$(mktemp -d "$HOME/tmp.XXXXXX")"
cd "$WORK_DIR" || { log_error "Failed to change to working directory"; exit 1; }

download_with_retries() {
    local url=$1
    local output_file=$2

    while true; do
        log "Attempting to download $url..."
        if curl -s -f -L "$url" -o "$output_file"; then
            log "Successfully downloaded $url"
            break
        else
            log "Failed to download $url. Retrying in 5 seconds..."
            rm -f "$output_file"
            sleep 5
        fi
    done
}

git_clone_with_retries() {
    local repo_url=$1
    local target_dir=$2

    while true; do
        log "Attempting to clone $repo_url..."
        if git clone "$repo_url" "$target_dir"; then
            log "Successfully cloned $repo_url"
            break
        else
            log "Failed to clone $repo_url. Retrying in 5 seconds..."
            rm -rf "$target_dir"
            sleep 5
        fi
    done
}

if [[ "$zeronet_source" == http*".git" ]]; then
    git_clone_with_retries "$zeronet_source" "zeronet_repo"
    base_dir="$WORK_DIR/zeronet_repo"
elif [[ "$zeronet_source" == http*".zip" ]] || [[ "$zeronet_source" == http*".tar.gz" ]]; then
    download_with_retries "$zeronet_source" "zeronet_archive"
    if [[ "$zeronet_source" == *.zip ]]; then
        unzip -o zeronet_archive -d "$WORK_DIR" || { log_error "Failed to unzip $zeronet_source"; exit 1; }
    elif [[ "$zeronet_source" == *.tar.gz ]]; then
        tar -xzf zeronet_archive -C "$WORK_DIR" || { log_error "Failed to extract $zeronet_source"; exit 1; }
    fi
    rm zeronet_archive
    zeronet_py_path=$(find "$WORK_DIR" -type f -name 'zeronet.py' | head -n 1)
    if [ -z "$zeronet_py_path" ]; then
        log_error "zeronet.py not found after extraction."
        exit 1
    fi
    base_dir=$(dirname "$zeronet_py_path")
elif [ -f "$zeronet_source" ]; then
    cp "$zeronet_source" zeronet_archive
    if [[ "$zeronet_source" == *.zip ]]; then
        unzip -o zeronet_archive -d "$WORK_DIR" || { log_error "Failed to unzip local file $zeronet_source"; exit 1; }
    elif [[ "$zeronet_source" == *.tar.gz ]]; then
        tar -xzf zeronet_archive -C "$WORK_DIR" || { log_error "Failed to extract local file $zeronet_source"; exit 1; }
    else
        log_error "Unsupported file format. Please provide a .zip or .tar.gz file."
        exit 1
    fi
    rm zeronet_archive
    zeronet_py_path=$(find "$WORK_DIR" -type f -name 'zeronet.py' | head -n 1)
    if [ -z "$zeronet_py_path" ]; then
        log_error "zeronet.py not found after extraction."
        exit 1
    fi
    base_dir=$(dirname "$zeronet_py_path")
else
    log_error "Invalid input. Please provide a valid Git URL, ZIP URL, or file path."
    exit 1
fi

log "Adjusting ownership of files before moving..."
chmod -R u+rwX "$base_dir" || { log_error "Failed to adjust permissions on extracted files"; exit 1; }

log "Moving extracted files to $ZERONET_DIR..."
mv "$base_dir"/* "$ZERONET_DIR"/ || { log_error "Failed to move extracted files"; exit 1; }

rm -rf "$WORK_DIR"

if [ ! -f "$ZERONET_DIR/zeronet.py" ]; then
    log_error "zeronet.py not found in the expected directory."
    exit 1
fi

cd "$ZERONET_DIR" || exit 1

if [ ! -d "$ZERONET_DIR/venv" ]; then
    python3 -m venv "$ZERONET_DIR/venv"
fi

source "$ZERONET_DIR/venv/bin/activate"

chmod -R u+rwX "$ZERONET_DIR"

if [ -f requirements.txt ]; then
    chmod 644 requirements.txt
    if ! pip install -r requirements.txt; then
        log_error "Failed to install from requirements.txt"
        exit 1
    fi
fi

mkdir -p ./data
chmod -R u+rwX ./data

if [[ "$users_json_source" == http* ]]; then
    mkdir -p data
    download_with_retries "$users_json_source" "data/users.json"
elif [ -n "$users_json_source" ]; then
    if [ -f "$users_json_source" ]; then
        mkdir -p data
        cp "$users_json_source" data/users.json || { log_error "Failed to copy users.json"; exit 1; }
        log "users.json copied successfully from $users_json_source"
    else
        log_error "File not found: $users_json_source"
        exit 1
    fi
fi

mkdir -p ./data
chmod -R u+rwX ./data

mkdir -p $PREFIX/var/log/

TRACKERS_FILE="$ZERONET_DIR/trackers.txt"

update_trackers() {
    log "Updating trackers list..."
    trackers_urls=(
        "https://cf.trackerslist.com/best.txt"
        "https://bitbucket.org/xiu2/trackerslistcollection/raw/master/best.txt"
        "https://cdn.jsdelivr.net/gh/XIU2/TrackersListCollection/best.txt"
        "https://fastly.jsdelivr.net/gh/XIU2/TrackersListCollection/best.txt"
        "https://gcore.jsdelivr.net/gh/XIU2/TrackersListCollection/best.txt"
        "https://cdn.statically.io/gh/XIU2/TrackersListCollection/best.txt"
        "https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/best.txt"
    )

    user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"

    for tracker_url in "${trackers_urls[@]}"; do
        log "Attempting to download tracker list from $tracker_url..."
        if curl -A "$user_agent" -s -f "$tracker_url" -o "$TRACKERS_FILE"; then
            log "Successfully downloaded tracker list from $tracker_url"
            chmod 644 "$TRACKERS_FILE"
            return
        else
            log "Failed to download from $tracker_url."
        fi
    done
    log_error "Failed to download from any URL. Retrying in 5 seconds..."
    sleep 5
}

generate_random_port() {
    log "Generating a random, collision-free port number for ZeroNet..."

    EXCLUDED_PORTS=($TOR_PROXY_PORT $TOR_CONTROL_PORT)

    while true; do
        RANDOM_PORT=$(shuf -i 1025-65535 -n 1)
        if [[ " ${EXCLUDED_PORTS[@]} " =~ " $RANDOM_PORT " ]]; then
            log "Port $RANDOM_PORT is excluded (Tor port). Generating a new port..."
            continue
        fi
        if netstat -tuln | grep -q ":$RANDOM_PORT "; then
            log "Port $RANDOM_PORT is in use. Generating a new port..."
            continue
        fi
        break
    done

    log "Selected port $RANDOM_PORT for ZeroNet."
    FILESERVER_PORT=$RANDOM_PORT
    log "Assigned FILESERVER_PORT = $FILESERVER_PORT"
}

create_zeronet_conf() {
    local conf_file="$ZERONET_DIR/zeronet.conf"

    cat > "$conf_file" << EOL
[global]
data_dir = $ZERONET_DIR/data
log_dir = $PREFIX/var/log/zeronet
ui_ip = 127.0.0.1
ui_port = 43110
tor_controller = 127.0.0.1:$TOR_CONTROL_PORT
tor_proxy = 127.0.0.1:$TOR_PROXY_PORT
trackers_file = $TRACKERS_FILE
language = en
tor = enable
fileserver_port = $FILESERVER_PORT
ip_external =
EOL
    log "ZeroNet configuration file created at $conf_file with security settings"
}

configure_tor() {
    log "Configuring Tor..."
    mkdir -p $HOME/.tor
    mkdir -p $PREFIX/var/log/tor
    mkdir -p $HOME/.tor/ZeroNet

    cat > $HOME/.tor/torrc << EOL
SocksPort $TOR_PROXY_PORT
ControlPort $TOR_CONTROL_PORT
CookieAuthentication 1
HiddenServiceDir $HOME/.tor/ZeroNet
HiddenServicePort 80 127.0.0.1:$FILESERVER_PORT
HiddenServiceVersion 3
Log notice file $PREFIX/var/log/tor/notices.log
EOL
    log "Tor configuration created at $HOME/.tor/torrc"
}

update_trackers
generate_random_port
create_zeronet_conf
configure_tor

log "Starting Tor service..."
tor -f $HOME/.tor/torrc &
TOR_PID=$!

log "Waiting for Tor to start and generate the hidden service..."
for i in {1..60}; do  # Increased wait time to 60 seconds
    if [ -f "$HOME/.tor/ZeroNet/hostname" ]; then
        ONION_ADDRESS=$(cat "$HOME/.tor/ZeroNet/hostname")
        log "Onion address generated: $ONION_ADDRESS"
        # Update ZeroNet configuration
        sed -i "s/^ip_external =.*/ip_external = $ONION_ADDRESS/" "$ZERONET_DIR/zeronet.conf"
        break
    fi
    sleep 1
done

if [ -z "$ONION_ADDRESS" ]; then
    log_error "Failed to retrieve onion address. Check Tor logs for issues."
    exit 1
fi

if kill -0 $TOR_PID 2>/dev/null; then
    log "Tor process is still running. Proceeding with hidden service setup."
else
    log_error "Tor process is not running. There may have been an issue starting Tor."
    exit 1
fi

if [[ $boot_setup =~ ^[Yy]$ ]]; then
    cat > "$BOOT_SCRIPT" << EOL
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock

ZERONET_DIR="$HOME/apps/zeronet"
TORRC_FILE="$HOME/.tor/torrc"

export PATH=\$PATH:\$PREFIX/bin
export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:\$PREFIX/lib

start_tor() {
    tor -f "\$TORRC_FILE" &
    # Wait until Tor is ready
    for i in {1..30}; do
        if [ -f "\$HOME/.tor/ZeroNet/hostname" ]; then
            break
        fi
        sleep 1
    done
}

start_zeronet() {
    cd "\$ZERONET_DIR"
    . ./venv/bin/activate
    python3 zeronet.py --config_file "\$ZERONET_DIR/zeronet.conf" &

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

check_openssl() {
    if command -v openssl >/dev/null 2>&1; then
        log "OpenSSL is available. Version: $(openssl version)"
    else
        log_error "OpenSSL is not found in PATH. Please ensure it's installed."
        exit 1
    fi
}

start_zeronet() {
    cd $ZERONET_DIR
    . ./venv/bin/activate

    # Add Termux bin to PATH
    export PATH=$PATH:$PREFIX/bin

    # Check for existing ZeroNet processes
    if pgrep -f "python3.*zeronet.py" > /dev/null; then
        log "Existing ZeroNet process found. Terminating..."
        pkill -f "python3.*zeronet.py"
        sleep 5  # Wait for the process to terminate
    fi

    # Remove lock file if it exists
    LOCK_FILE="$ZERONET_DIR/data/lock.pid"
    if [ -f "$LOCK_FILE" ]; then
        log "Removing stale lock file..."
        rm "$LOCK_FILE"
    fi

    if [ -d "$ZERONET_DIR/plugins/disabled-Bootstrapper" ]; then
        mv "$ZERONET_DIR/plugins/disabled-Bootstrapper" "$ZERONET_DIR/plugins/Bootstrapper"
        log "Renamed disabled-Bootstrapper to Bootstrapper"
    else
        log "disabled-Bootstrapper directory not found"
    fi

    # Add a small delay before starting ZeroNet
    sleep 2

    # Start ZeroNet with the updated PATH
    python3 zeronet.py --config_file $ZERONET_DIR/zeronet.conf &
    ZERONET_PID=$!
    log "ZeroNet started with PID $ZERONET_PID"
    termux-notification --title "ZeroNet Running" --content "ZeroNet started with PID $ZERONET_PID" --ongoing

    # Wait a moment to check if the process is still running
    sleep 5
    if ! ps -p $ZERONET_PID > /dev/null; then
        log_error "ZeroNet process terminated unexpectedly. Check logs for details."
        exit 1
    fi
}

check_openssl
log "Starting ZeroNet..."
start_zeronet

log "ZeroNet started. Waiting 10 seconds before further operations..."
sleep 10

log "Shutting down ZeroNet via API..."
curl -X POST http://127.0.0.1:43110/ZeroNet-Internal/Shutdown

log "Downloading and extracting ZIP file..."
ZIP_URL="https://0net-preview.com/ZeroNet-Internal/Zip?address=15CEFKBRHFfAP9rmL6hhLmHoXrrgmw4B5o"
ZIP_DIR="$ZERONET_DIR/data/15CEFKBRHFfAP9rmL6hhLmHoXrrgmw4B5o"

mkdir -p "$ZIP_DIR"
curl -L "$ZIP_URL" -o "$ZIP_DIR/content.zip"
unzip -o "$ZIP_DIR/content.zip" -d "$ZIP_DIR"
rm "$ZIP_DIR/content.zip"

log "ZIP file extracted to $ZIP_DIR"

update_trackers

log "Restarting ZeroNet..."
start_zeronet

# Adjusted the process check using pgrep
if ! pgrep -f "zeronet.py" > /dev/null; then
    log_error "Failed to start ZeroNet"
    termux-notification --title "ZeroNet Error" --content "Failed to start ZeroNet"
    exit 1
fi

view_log() {
    termux-dialog confirm -i "View last 50 lines of log?" -t "View Log"
    if [ $? -eq 0 ]; then
        LOG_CONTENT=$(tail -n 50 "$PREFIX/var/log/zeronet/debug.log")
        termux-dialog text -t "ZeroNet Log (last 50 lines)" -i "$LOG_CONTENT"
    fi
}

restart_zeronet() {
    termux-dialog confirm -i "Are you sure you want to restart ZeroNet?" -t "Restart ZeroNet"
    if [ $? -eq 0 ]; then
        log "Restarting ZeroNet..."
        if [ ! -z "$ZERONET_PID" ]; then
            kill $ZERONET_PID
            sleep 5  # Wait for the process to terminate
        fi
        start_zeronet
        log "ZeroNet restarted with PID $ZERONET_PID"
        termux-notification --title "ZeroNet Restarted" --content "New PID: $ZERONET_PID"
    fi
}

while true; do
    ACTION=$(termux-dialog sheet -v "View Log,Restart ZeroNet,Exit" -t "ZeroNet Management")
    case $ACTION in
        *"View Log"*)
            view_log
            ;;
        *"Restart ZeroNet"*)
            restart_zeronet
            ;;
        *"Exit"*)
            termux-dialog confirm -i "Are you sure you want to exit? This will stop ZeroNet." -t "Exit ZeroNet"
            if [ $? -eq 0 ]; then
                log "Stopping ZeroNet and exiting..."
                kill $ZERONET_PID
                termux-notification-remove 1
                exit 0
            fi
            ;;
        *)
            termux-toast "Invalid choice. Please try again."
            ;;
    esac
done