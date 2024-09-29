#!/data/data/com.termux/files/usr/bin/bash

termux-wake-lock

echo "ZeroNet installation: Step 1 of 4 - Updating Termux repositories"
echo "Please select your preferred mirror when prompted."
termux-change-repo
echo "Repository update completed."

echo "ZeroNet installation: Step 2 of 4 - Setting up Termux storage"
echo "You may need to grant storage permission."
termux-setup-storage
echo "Storage setup completed."

ZERONET_DIR="$HOME/apps/zeronet"
LOG_FILE="$HOME/zeronet_install.log"
TORRC_FILE="$HOME/.tor/torrc"
TOR_PROXY_PORT=49050
TOR_CONTROL_PORT=49051
UI_IP="127.0.0.1"
UI_PORT=43110
SYNCRONITE_ADDRESS="15CEFKBRHFfAP9rmL6hhLmHoXrrgmw4B5o"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"

# Create a temporary directory in the user's home folder
WORK_DIR="$HOME/zeronet_tmp"
mkdir -p "$WORK_DIR"
chmod -R 755 "$WORK_DIR"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log_and_show() {
    log "$1"
    echo "$1"
}

log_error() {
    log "[ERROR] $1"
    echo "Error: $1" >&2
    exit 1
}

total_steps=20
current_step=0

show_progress() {
    current_step=$((current_step + 1))
    percentage=$((current_step * 100 / total_steps))
    printf "\rProgress: %3d%%" $percentage
}

update_progress() {
    show_progress
    echo  # Move to a new line after updating progress
}

echo "ZeroNet installation: Step 3 of 4 - Gathering information"

echo "Please provide the Git clone URL or path to the ZeroNet source code archive (Git URL, .zip, or .tar.gz):"
read -r zeronet_source

echo "Please provide a URL or path to users.json, or press Enter to skip. users.json is where your ZeroNet accounts are stored and/or will be stored."
read -r users_json_source

echo "Do you want to set up an onion tracker? This will strengthen ZeroNet. This doesn't work for every Android device. (y/n)"
read -r onion_tracker_setup

echo "Do you want to set up auto-start with Termux:Boot? This will start ZeroNet after your device is rebooted. (y/n)"
read -r boot_setup

echo "ZeroNet installation: Step 4 of 4 - Installing ZeroNet"
echo "This may take several minutes. Please be patient. If you have Termux:API installed, you'll receive notifications with further instructions when ZeroNet is installed and running."

update_mirrors() {
    local max_attempts=5
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if yes | pkg update &>/dev/null; then
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
update_progress

yes | pkg upgrade &>/dev/null
update_progress

required_packages=(
    termux-tools termux-keyring python
    netcat-openbsd binutils git cmake libffi
    curl unzip libtool automake autoconf pkg-config findutils
    clang make termux-api tor perl jq rust openssl-tool iproute2
)

install_package() {
    local package=$1
    local max_attempts=3
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if yes | pkg install -y "$package" &>/dev/null; then
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
    if ! dpkg -s "$package" &>/dev/null 2>&1; then
        install_package "$package" || exit 1
    fi
done
update_progress

log "Installing OpenSSL from Termux repository..."
yes | pkg install -y openssl-tool &>/dev/null || log_error "Failed to install OpenSSL from repository"

log "OpenSSL installation completed."
update_progress

install_python_packages() {
    log "Installing required Python packages..."
    export CFLAGS="-I$PREFIX/include"
    export LDFLAGS="-L$PREFIX/lib"

    pip install --upgrade pip setuptools wheel &>/dev/null

    MAX_RETRIES=3
    RETRY_DELAY=10

    install_package_with_retry() {
        local package=$1
        local retries=0
        while [ $retries -lt $MAX_RETRIES ]; do
            if pip install --no-deps $package &>/dev/null; then
                log "Successfully installed $package"
                return 0
            else
                retries=$((retries + 1))
                log "Failed to install $package. Attempt $retries of $MAX_RETRIES."
                if [ $retries -lt $MAX_RETRIES ]; then
                    log "Retrying in $RETRY_DELAY seconds..."
                    sleep $RETRY_DELAY
                    # Kill any hanging processes
                    pkill -f "pip install" &>/dev/null
                    # Clean up temporary directories
                    rm -rf "$HOME/.cache/pip"
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
            if ! pip install --only-binary=:all: $package &>/dev/null; then
                if [ "$package" = "cryptography" ]; then
                    log "Attempting to install cryptography without Rust..."
                    if ! CRYPTOGRAPHY_DONT_BUILD_RUST=1 pip install cryptography &>/dev/null; then
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
    python3 -c "import gevent; import Crypto; import cryptography; import OpenSSL; print('All required Python packages successfully installed')" &>/dev/null || log_error "Failed to import one or more required Python packages"
}

install_python_packages || exit 1
update_progress

if [ -d "$ZERONET_DIR" ] && [ "$(ls -A "$ZERONET_DIR")" ]; then
    log "The directory $ZERONET_DIR already exists and is not empty."
    log "Proceeding to adjust permissions and clean the directory."
    chmod -R u+rwX "$ZERONET_DIR" &>/dev/null || { log_error "Failed to adjust permissions on existing directory"; exit 1; }
    rm -rf "$ZERONET_DIR" || { log_error "Failed to remove existing directory"; exit 1; }
fi

mkdir -p "$ZERONET_DIR"

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
        if git clone "$repo_url" "$target_dir" &>/dev/null; then
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
        unzip -o zeronet_archive -d "$WORK_DIR" &>/dev/null || { log_error "Failed to unzip $zeronet_source"; exit 1; }
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
        unzip -o zeronet_archive -d "$WORK_DIR" &>/dev/null || { log_error "Failed to unzip local file $zeronet_source"; exit 1; }
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
update_progress

log "Adjusting ownership of files before moving..."
chmod -R u+rwX "$base_dir" &>/dev/null || { log_error "Failed to adjust permissions on extracted files"; exit 1; }

log "Moving extracted files to $ZERONET_DIR..."
mv "$base_dir"/* "$ZERONET_DIR"/ || { log_error "Failed to move extracted files"; exit 1; }

if [ ! -f "$ZERONET_DIR/zeronet.py" ]; then
    log_error "zeronet.py not found in the expected directory."
    exit 1
fi

cd "$ZERONET_DIR" || exit 1

if [ ! -d "$ZERONET_DIR/venv" ]; then
    python3 -m venv "$ZERONET_DIR/venv" &>/dev/null
fi

source "$ZERONET_DIR/venv/bin/activate"

chmod -R u+rwX "$ZERONET_DIR" &>/dev/null

if [ -f requirements.txt ]; then
    chmod 644 requirements.txt &>/dev/null
    if ! pip install -r requirements.txt &>/dev/null; then
        log_error "Failed to install from requirements.txt"
        exit 1
    fi
fi
update_progress

install_contentfilter_plugin() {
    log "Installing ContentFilter plugin..."
    local plugins_dir="$ZERONET_DIR/plugins"
    local plugins_repo="https://github.com/ZeroNetX/ZeroNet-Plugins.git"
    local plugins_tmp_dir="$WORK_DIR/zeronet_plugins"

    if [ ! -d "$plugins_dir/ContentFilter" ]; then
        git_clone_with_retries "$plugins_repo" "$plugins_tmp_dir"

        if [ -d "$plugins_tmp_dir/ContentFilter" ]; then
            mv "$plugins_tmp_dir/ContentFilter" "$plugins_dir/ContentFilter"
            log "Installed ContentFilter plugin"
        else
            log "ContentFilter plugin not found in the repository"
        fi

        # Clean up
        rm -rf "$plugins_tmp_dir"
    else
        log "ContentFilter plugin already exists, skipping installation"
    fi

    log "ContentFilter plugin installation completed."
}

# Install ContentFilter plugin
install_contentfilter_plugin
update_progress

mkdir -p ./data
chmod -R u+rwX ./data &>/dev/null

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
update_progress

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

    for tracker_url in "${trackers_urls[@]}"; do
        log "Attempting to download tracker list from $tracker_url..."
        if curl -A "$USER_AGENT" -s -f "$tracker_url" -o "$TRACKERS_FILE"; then
            log "Successfully downloaded tracker list from $tracker_url"
            chmod 644 "$TRACKERS_FILE" &>/dev/null
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
        
        # Check if the port is in the excluded list
        if [[ " ${EXCLUDED_PORTS[@]} " =~ " $RANDOM_PORT " ]]; then
            log "Port $RANDOM_PORT is excluded (Tor port). Generating a new port..."
            continue
        fi
        
        # Check if the port is already in use
        if ! ss -tuln | grep -q ":$RANDOM_PORT "; then
            log "Selected available port $RANDOM_PORT for ZeroNet."
            FILESERVER_PORT=$RANDOM_PORT
            log "Assigned FILESERVER_PORT = $FILESERVER_PORT"
            break
        else
            log "Port $RANDOM_PORT is in use. Generating a new port..."
        fi
    done
}

create_zeronet_conf() {
    local conf_file="$ZERONET_DIR/zeronet.conf"

    cat > "$conf_file" << EOL
[global]
homepage = 191CazMVNaAcT9Y1zhkxd9ixMBPs59g2um
data_dir = $ZERONET_DIR/data
log_dir = $PREFIX/var/log/zeronet
ui_ip = $UI_IP
ui_port = $UI_PORT
tor_controller = $UI_IP:$TOR_CONTROL_PORT
tor_proxy = $UI_IP:$TOR_PROXY_PORT
trackers_file = $TRACKERS_FILE
 {data_dir}/$SYNCRONITE_ADDRESS/cache/1/Syncronite.html
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

    # Mandatory configuration
    cat > $TORRC_FILE << EOL
SocksPort $TOR_PROXY_PORT
ControlPort $TOR_CONTROL_PORT
CookieAuthentication 1
Log notice file $PREFIX/var/log/tor/notices.log
EOL

    # Optional onion service configuration
    if [[ $onion_tracker_setup =~ ^[Yy]$ ]]; then
        mkdir -p $HOME/.tor/ZeroNet
        cat >> $TORRC_FILE << EOL
HiddenServiceDir $HOME/.tor/ZeroNet
HiddenServicePort 80 127.0.0.1:$FILESERVER_PORT
HiddenServiceVersion 3
EOL
        log "Onion tracker configuration added to Tor configuration"
    else
        log "Onion tracker setup skipped, but mandatory Tor configuration is in place"
    fi

    log "Tor configuration created at $TORRC_FILE"
}

update_trackers
generate_random_port
create_zeronet_conf
configure_tor
update_progress

log "Starting Tor service..."
tor -f $TORRC_FILE &>/dev/null &
TOR_PID=$!

if [[ $onion_tracker_setup =~ ^[Yy]$ ]]; then
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
else
    log "Skipping onion address generation as onion tracker setup was not requested"
fi

if kill -0 $TOR_PID 2>/dev/null; then
    log "Tor process is still running. Proceeding with setup."
else
    log_error "Tor process is not running. There may have been an issue starting Tor."
    exit 1
fi
update_progress

TERMUX_BOOT_DIR="$HOME/.termux/boot"
BOOT_SCRIPT="$TERMUX_BOOT_DIR/start-zeronet"

if [[ $boot_setup =~ ^[Yy]$ ]]; then
    # Check if Termux:Boot directory exists, create if it doesn't
    if [ ! -d "$TERMUX_BOOT_DIR" ]; then
        log "Termux:Boot directory not found. Creating it..."
        mkdir -p "$TERMUX_BOOT_DIR"
        if [ $? -ne 0 ]; then
            log_error "Failed to create Termux:Boot directory. Make sure Termux:Boot is installed."
            log "Skipping boot script creation."
        else
            log "Termux:Boot directory created successfully."
        fi
    fi

    # Only create the boot script if the directory exists
    if [ -d "$TERMUX_BOOT_DIR" ]; then
        cat > "$BOOT_SCRIPT" << EOL
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock

export PATH=$PATH:/data/data/com.termux/files/usr/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/data/data/com.termux/files/usr/lib

start_tor() {
    tor -f "/data/data/com.termux/files/home/.tor/torrc" &>/dev/null &
    # Wait until Tor is ready
    for i in {1..30}; do
        if [ -f "/data/data/com.termux/files/home/.tor/ZeroNet/hostname" ]; then
            break
        fi
        sleep 1
    done
}

start_zeronet() {
    cd "/data/data/com.termux/files/home/apps/zeronet"
    . ./venv/bin/activate
    python3 zeronet.py &>/dev/null &

    ZERONET_PID=$!
    echo "ZeroNet started"
    termux-notification --id "zeronet_status" --title "ZeroNet Running" --content "ZeroNet started" --ongoing
    termux-notification --id "zeronet_url" --title "ZeroNet URL" --content "http://$UI_IP:$UI_PORT" --button1 "Copy" --button1-action "termux-clipboard-set 'http://$UI_IP:$UI_PORT'"
}

start_tor
start_zeronet
EOL

chmod +x "$BOOT_SCRIPT"
        log "Termux Boot script created at $BOOT_SCRIPT"
    else
        log "Termux:Boot directory not found. Boot script creation skipped."
    fi
else
    log "Boot script setup skipped. To set up auto-start later, ensure Termux:Boot is installed and run this script again."
fi
update_progress

check_openssl() {
    if command -v openssl &>/dev/null; then
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

    if [[ $onion_tracker_setup =~ ^[Yy]$ ]]; then
        if [ -d "$ZERONET_DIR/plugins/disabled-Bootstrapper" ]; then
            mv "$ZERONET_DIR/plugins/disabled-Bootstrapper" "$ZERONET_DIR/plugins/Bootstrapper"
            log "Renamed disabled-Bootstrapper to Bootstrapper"
        else
            log "disabled-Bootstrapper directory not found"
        fi
    else
        log "Skipping renaming of disabled-Bootstrapper folder"
    fi

    # Add a small delay before starting ZeroNet
    sleep 2

    # Start ZeroNet with the updated PATH
    python3 zeronet.py &>/dev/null &
    ZERONET_PID=$!
    log "ZeroNet started with PID $ZERONET_PID"
    termux-notification --id "zeronet_status" --title "ZeroNet Running" --content "ZeroNet started with PID $ZERONET_PID" --ongoing
    termux-notification --id "zeronet_url" --title "ZeroNet URL" --content "http://$UI_IP:$UI_PORT" --button1 "Copy" --button1-action "termux-clipboard-set 'http://$UI_IP:$UI_PORT'"

    # Wait a moment to check if the process is still running
    sleep 5
    if ! ps -p $ZERONET_PID > /dev/null; then
        log_error "ZeroNet process terminated unexpectedly. Check logs for details."
        exit 1
    fi
}

# Download and unpack the GeoLite2 City database after the first ZeroNet shutdown and before the next run

log "Downloading GeoLite2 City database..."

GEOIP_DB_URL="https://raw.githubusercontent.com/aemr3/GeoLite2-Database/master/GeoLite2-City.mmdb.gz"
GEOIP_DB_PATH="$ZERONET_DIR/data/GeoLite2-City.mmdb"

download_geoip_database() {
    while true; do
        log "Attempting to download GeoLite2 City database..."
        if curl -A "$USER_AGENT" \
            -H "Accept: application/octet-stream" \
            -s -f -L "$GEOIP_DB_URL" -o "${GEOIP_DB_PATH}.gz"; then
            log "Successfully downloaded GeoLite2 City database."
            gunzip -f "${GEOIP_DB_PATH}.gz" &>/dev/null
            chmod 644 "$GEOIP_DB_PATH" &>/dev/null
            log "GeoLite2 City database unpacked and ready at $GEOIP_DB_PATH"
            break
        else
            log "Failed to download GeoLite2 City database. Retrying in 5 seconds..."
            sleep 5
        fi
    done
}

# Call the function to download and unpack the GeoLite2 City database
download_geoip_database
update_progress

check_openssl
log "Starting ZeroNet..."
start_zeronet
update_progress

log "ZeroNet started. Waiting 10 seconds before further operations..."
sleep 10

download_syncronite() {
    log "Downloading Syncronite content..."
    ZIP_URL="https://0net-preview.com/ZeroNet-Internal/Zip?address=$SYNCRONITE_ADDRESS"
    ZIP_DIR="$ZERONET_DIR/data/$SYNCRONITE_ADDRESS"

    mkdir -p "$ZIP_DIR"
    while true; do
        if curl -L "$ZIP_URL" -o "$ZIP_DIR/content.zip"; then
            unzip -o "$ZIP_DIR/content.zip" -d "$ZIP_DIR" &>/dev/null
            rm "$ZIP_DIR/content.zip"
            log "Syncronite content downloaded and extracted to $ZIP_DIR"
            return 0
        else
            log "Failed to download Syncronite content. Retrying in 5 seconds..."
            sleep 5
        fi
    done
}

provide_syncronite_instructions() {
    local instructions="To add Syncronite to ZeroNet:
1. Visit http://$UI_IP:$UI_PORT/$SYNCRONITE_ADDRESS
2. ZeroNet will add Syncronite to your dashboard so you'll receive trackers list updates as they come.
Note: Only open links to ZeroNet sites that you trust."
    
    log_and_show "To add Syncronite to your ZeroNet:"
    log_and_show "1. Open this link in your web browser: http://$UI_IP:$UI_PORT/$SYNCRONITE_ADDRESS"
    log_and_show "2. ZeroNet will automatically add Syncronite to your dashboard when you visit the link."
    log_and_show "Note: Only open links to ZeroNet sites that you trust."
    
    termux-notification --id "syncronite_url" --title "Syncronite URL" --content "http://$UI_IP:$UI_PORT/$SYNCRONITE_ADDRESS" --button1 "Copy" --button1-action "termux-clipboard-set 'http://$UI_IP:$UI_PORT/$SYNCRONITE_ADDRESS'"
    
    termux-notification --id "syncronite_instructions" --title "Syncronite Instructions" --content "$instructions"
}

if download_syncronite; then
    log "Syncronite content is now available in your ZeroNet data directory."
    provide_syncronite_instructions
else
    log_error "Failed to prepare Syncronite content. You may need to add it manually later."
fi
update_progress

update_trackers
update_progress

log_and_show "ZeroNet setup complete."

# Adjusted the process check using pgrep
if ! pgrep -f "zeronet.py" > /dev/null; then
    log_error "Failed to start ZeroNet"
    termux-notification --id "zeronet_error" --title "ZeroNet Error" --content "Failed to start ZeroNet"
    termux-notification --id "zeronet_url" --remove
    exit 1
fi

log_and_show "ZeroNet is running successfully. Syncronite content is available."
provide_syncronite_instructions

# Clean up
rm -rf "$WORK_DIR"

log_and_show "ZeroNet installation completed successfully!"
log_and_show "You can now access ZeroNet at http://$UI_IP:$UI_PORT"

# Final progress update
update_progress

log "Installation process completed. Please review the log file at $LOG_FILE for any important messages or errors."

termux-notification --id "zeronet_complete" --title "ZeroNet Installation Complete" --content "ZeroNet is now installed and running. Access it at http://$UI_IP:$UI_PORT"

# Final instructions
echo ""
echo "Important Instructions:"
echo "1. To access ZeroNet, open this URL in your web browser: http://$UI_IP:$UI_PORT"
echo "2. To add Syncronite, visit: http://$UI_IP:$UI_PORT/$SYNCRONITE_ADDRESS"
echo "3. If you set up auto-start, ZeroNet will start automatically after device reboot."
echo "4. To manually start ZeroNet in the future, run:"
echo "   cd $ZERONET_DIR && source venv/bin/activate && python zeronet.py"
echo ""
echo "Thank you for installing ZeroNet. Enjoy your decentralized web experience!"