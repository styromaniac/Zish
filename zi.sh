#!/data/data/com.termux/files/usr/bin/bash

termux-wake-lock

termux-change-repo

termux-setup-storage

ZERONET_DIR="$HOME/apps/zeronet"
LOG_FILE="$HOME/zeronet_install.log"
TORRC_FILE="$HOME/.tor/torrc"
TOR_PROXY_PORT=49050
TOR_CONTROL_PORT=49051
UI_IP="127.0.0.1"
UI_PORT=43110
SYNCRONITE_ADDRESS="15CEFKBRHFfAP9rmL6hhLmHoXrrgmw4B5o"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"

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

log "Do you want to set up an onion tracker? This will strengthen ZeroNet. (y/n)"
read -r onion_tracker_setup

log "Do you want to set up auto-start with Termux:Boot? (y/n)"
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

    for tracker_url in "${trackers_urls[@]}"; do
        log "Attempting to download tracker list from $tracker_url..."
        if curl -A "$USER_AGENT" -s -f "$tracker_url" -o "$TRACKERS_FILE"; then
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
        
        # Check if the port is in the excluded list
        if [[ " ${EXCLUDED_PORTS[@]} " =~ " $RANDOM_PORT " ]]; then
            log "Port $RANDOM_PORT is excluded (Tor port). Generating a new port..."
            continue
        fi
        
        # Check if the port is already in use
        if ! netstat -tuln | grep -q ":$RANDOM_PORT "; then
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

log "Starting Tor service..."
tor -f $TORRC_FILE &
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

ZERONET_DIR="$ZERONET_DIR"
TORRC_FILE="$TORRC_FILE"
UI_IP="$UI_IP"
UI_PORT="$UI_PORT"

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
        log "Termux:Boot directory not found. Boot script creation skipped."
    fi
else
    log "Boot script setup skipped. To set up auto-start later, ensure Termux:Boot is installed and run this script again."
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
            gunzip -f "${GEOIP_DB_PATH}.gz"
            chmod 644 "$GEOIP_DB_PATH"
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

check_openssl
log "Starting ZeroNet..."
start_zeronet

log "ZeroNet started. Waiting 10 seconds before further operations..."
sleep 10

log "Downloading and extracting Syncronite ZIP file..."
ZIP_URL="https://0net-preview.com/ZeroNet-Internal/Zip?address=$SYNCRONITE_ADDRESS"
ZIP_DIR="$ZERONET_DIR/data/$SYNCRONITE_ADDRESS"

mkdir -p "$ZIP_DIR"
curl -L "$ZIP_URL" -o "$ZIP_DIR/content.zip"
unzip -o "$ZIP_DIR/content.zip" -d "$ZIP_DIR"
rm "$ZIP_DIR/content.zip"

log "Syncronite ZIP file extracted to $ZIP_DIR"

add_syncronite_to_dashboard() {
    local sites_json="$ZERONET_DIR/data/sites.json"
    local content_json="$ZERONET_DIR/data/$SYNCRONITE_ADDRESS/content.json"

    log "Adding Syncronite to ZeroNet dashboard..."

    # Ensure the Syncronite directory exists
    if [ ! -d "$ZERONET_DIR/data/$SYNCRONITE_ADDRESS" ]; then
        log "Creating Syncronite directory..."
        mkdir -p "$ZERONET_DIR/data/$SYNCRONITE_ADDRESS"
    fi

    # Create or update the content.json for Syncronite
    if [ ! -f "$content_json" ]; then
        log "Creating content.json for Syncronite..."
        echo '{
            "address": "'$SYNCRONITE_ADDRESS'",
            "title": "Syncronite",
            "description": "Syncronite ZeroNet site",
            "cloneable": false,
            "cloned_from": "1HeLLo4uzjaLetFx6NH3PMwFP3qbRbTf3D"
        }' > "$content_json"
    fi

    # Add or update Syncronite in sites.json
    if [ -f "$sites_json" ]; then
        log "Updating sites.json with Syncronite..."
        # Use jq to add or update the Syncronite entry
        jq --arg addr "$SYNCRONITE_ADDRESS" --arg time "$(date +%s)" '
        .[$addr] = {
            "added": $time,
            "address": $addr,
            "peers": 0,
            "modified": $time,
            "size": 0,
            "size_optional": 0,
            "own": false
        }' "$sites_json" > "$sites_json.tmp" && mv "$sites_json.tmp" "$sites_json"
    else
        log "Creating new sites.json with Syncronite..."
        echo '{
            "'$SYNCRONITE_ADDRESS'": {
                "added": '$(date +%s)',
                "address": "'$SYNCRONITE_ADDRESS'",
                "peers": 0,
                "modified": '$(date +%s)',
                "size": 0,
                "size_optional": 0,
                "own": false
            }
        }' > "$sites_json"
    fi

    log "Syncronite added to ZeroNet dashboard."
}

# Call this function after starting ZeroNet
add_syncronite_to_dashboard

# Restart ZeroNet to apply changes
log "Restarting ZeroNet to apply changes..."
pkill -f "python3.*zeronet.py"
sleep 5
start_zeronet

log "Waiting 20 seconds for ZeroNet to fully initialize..."
sleep 20

update_trackers

log "ZeroNet setup complete with Syncronite loaded and added to the dashboard."

# Adjusted the process check using pgrep
if ! pgrep -f "zeronet.py" > /dev/null; then
    log_error "Failed to start ZeroNet"
    termux-notification --title "ZeroNet Error" --content "Failed to start ZeroNet"
    exit 1
fi

log "ZeroNet is running successfully with Syncronite loaded and added to the dashboard."