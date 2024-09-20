#!/data/data/com.termux/files/usr/bin/bash

set -e

LOG_FILE="$HOME/zeronet_install.log"

log_error() {
    echo "[ERROR] $1" | tee -a "$LOG_FILE"
}

termux-wake-lock

termux-change-repo

termux-setup-storage

update_mirrors() {
    local max_attempts=5
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if pkg update; then
            echo "Successfully updated package lists"
            return 0
        else
            echo "Failed to update package lists. Attempt $attempt of $max_attempts."
            if [ $attempt -lt $max_attempts ]; then
                echo "Trying a different mirror..."
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

required_packages=(
    termux-tools termux-keyring python
    netcat-openbsd binutils git cmake libffi openssl
    curl unzip libtool automake autoconf pkg-config findutils
    clang make termux-api tor
)

pkg_operation_with_retries() {
    local operation=$1
    shift
    local max_attempts=3
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if pkg "$operation" "$@"; then
            return 0
        else
            echo "pkg $operation failed. Attempt $attempt of $max_attempts."
            if [ $attempt -lt $max_attempts ]; then
                echo "Retrying in 5 seconds..."
                sleep 5
            fi
            ((attempt++))
        fi
    done
    return 1
}

install_package() {
    local package=$1
    local max_attempts=3
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if pkg install -y "$package"; then
            echo "Successfully installed $package"
            return 0
        else
            echo "Failed to install $package. Attempt $attempt of $max_attempts."
            if [ $attempt -lt $max_attempts ]; then
                echo "Retrying in 5 seconds..."
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

ZERONET_DIR=~/apps/zeronet
LOG_FILE="$ZERONET_DIR/zeronet_install.log"
mkdir -p "$(dirname "$ZERONET_DIR")"

log_error() {
    echo "[ERROR] $1" | tee -a "$LOG_FILE"
}

download_with_retries() {
    local url=$1
    local output_file=$2

    while true; do
        echo "Attempting to download $url..."
        if curl -s -f -L "$url" -o "$output_file"; then
            echo "Successfully downloaded $url"
            break
        else
            echo "Failed to download $url. Retrying in 5 seconds..."
            rm -f "$output_file"
            sleep 5
        fi
    done
}

git_operation_with_retries() {
    local operation=$1
    shift
    while true; do
        echo "Attempting Git operation: $operation $*"
        if $operation "$@"; then
            echo "Git operation successful: $operation $*"
            break
        else
            echo "Git operation failed: $operation $*. Retrying in 5 seconds..."
            sleep 5
        fi
    done
}

git_clone_with_retries() {
    local repo_url=$1
    local target_dir=$2

    while true; do
        echo "Attempting to clone $repo_url..."
        if git clone "$repo_url" "$target_dir"; then
            echo "Successfully cloned $repo_url"
            break
        else
            echo "Failed to clone $repo_url. Retrying in 5 seconds..."
            rm -rf "$target_dir"
            sleep 5
        fi
    done
}

if [ -d "$ZERONET_DIR" ] && [ "$(ls -A "$ZERONET_DIR")" ]; then
    echo "The directory $ZERONET_DIR already exists and is not empty."
    echo "Proceeding to adjust permissions and clean the directory."
    chmod -R u+rwX "$ZERONET_DIR" || { log_error "Failed to adjust permissions on existing directory"; exit 1; }
    rm -rf "$ZERONET_DIR" || { log_error "Failed to remove existing directory"; exit 1; }
fi

mkdir -p "$ZERONET_DIR"

WORK_DIR="$(mktemp -d)"
cd "$WORK_DIR" || { log_error "Failed to change to working directory"; exit 1; }

echo "Please provide the Git clone URL or path to the ZeroNet ZIP file (Git URL, .zip, or .tar.gz):"
read -r zeronet_source

while true; do
    if [[ "$zeronet_source" == http*".git" ]]; then
        git_clone_with_retries "$zeronet_source" "zeronet_repo"
        base_dir="$WORK_DIR/zeronet_repo"
        break
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
        break
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
        break
    else
        log_error "Invalid input. Please provide a valid Git URL, ZIP URL, or file path:"
        read -r zeronet_source
    fi
done

echo "Adjusting ownership of files before moving..."
chmod -R u+rwX "$base_dir" || { log_error "Failed to adjust permissions on extracted files"; exit 1; }

echo "Moving extracted files to $ZERONET_DIR..."
mv "$base_dir"/* "$ZERONET_DIR"/ || { log_error "Failed to move extracted files"; exit 1; }

rm -rf "$WORK_DIR"

if [ ! -f "$ZERONET_DIR/zeronet.py" ]; then
    log_error "zeronet.py not found in the expected directory."
    exit 1
fi

cd "$ZERONET_DIR" || exit 1

if [ ! -d "$ZERONET_DIR/venv" ]; then
    python -m venv "$ZERONET_DIR/venv"
fi

source "$ZERONET_DIR/venv/bin/activate"

pip_operation_with_retries() {
    local operation=$1
    shift
    local max_attempts=3
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if pip "$operation" "$@"; then
            return 0
        else
            echo "pip $operation failed. Attempt $attempt of $max_attempts."
            if [ $attempt -lt $max_attempts ]; then
                echo "Retrying in 5 seconds..."
                sleep 5
            fi
            ((attempt++))
        fi
    done
    return 1
}

pip install --upgrade pip setuptools wheel || { log_error "Failed to upgrade pip, setuptools, and wheel"; exit 1; }
pip install gevent pycryptodome || { log_error "Failed to install gevent and pycryptodome"; exit 1; }

export LIBRARY_PATH=$PREFIX/lib
export C_INCLUDE_PATH=$PREFIX/include
export LD_LIBRARY_PATH=$PREFIX/lib
export LIBSECP256K1_STATIC=1

pip uninstall -y coincurve
pip cache purge

pkg_operation_with_retries install autoconf automake libtool

cd ~
git_clone_with_retries https://github.com/bitcoin-core/secp256k1.git libsecp256k1
cd libsecp256k1

# Get the default branch name
default_branch=$(git symbolic-ref --short HEAD)
echo "Default branch is $default_branch"

# Fetch all tags
git fetch --tags

# Try to get the latest tag
latest_tag=$(git describe --tags $(git rev-list --tags --max-count=1))

if [ ! -z "$latest_tag" ]; then
    echo "Latest tag is $latest_tag"
    if git_operation_with_retries git checkout $latest_tag; then
        echo "Successfully checked out tag $latest_tag"
    else
        echo "Failed to checkout tag $latest_tag. Using default branch $default_branch."
    fi
else
    echo "No tags found. Using default branch $default_branch."
fi

# Ensure we're on a valid commit
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "HEAD is not a valid commit. Checking out $default_branch."
    git_operation_with_retries git checkout $default_branch
fi

git_operation_with_retries ./autogen.sh
./configure --prefix=$PREFIX --enable-module-recovery --enable-experimental --enable-module-ecdh
make
make install

install_coincurve() {
    local max_attempts=3
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        echo "Attempting to install coincurve (attempt $attempt of $max_attempts)..."
        if CFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib -lpython3.11 -lsecp256k1" pip install --no-cache-dir --no-binary :all: coincurve; then
            echo "coincurve installed successfully"
            return 0
        else
            echo "Failed to install coincurve. Retrying in 5 seconds..."
            pip uninstall -y coincurve
            pip cache purge
            sleep 5
            ((attempt++))
        fi
    done
    log_error "Failed to install coincurve after $max_attempts attempts."
    return 1
}

if ! install_coincurve; then
    echo "WARNING: coincurve installation failed. Some ZeroNet features may not work correctly."
fi

if python -c "from coincurve import PrivateKey; key = PrivateKey(); print(key.public_key.format())" > /dev/null 2>&1; then
    echo "coincurve installed successfully"
else
    echo "Failed to install coincurve"
    exit 1
fi

python -c "import pkg_resources; print(f'coincurve version: {pkg_resources.get_distribution(\"coincurve\").version}')"

cd ~
rm -rf libsecp256k1

cd "$ZERONET_DIR"

chmod -R u+rwX "$ZERONET_DIR"

if [ -f requirements.txt ]; then
    chmod 644 requirements.txt
    if ! pip_operation_with_retries install -r requirements.txt; then
        log_error "Failed to install from requirements.txt"
        exit 1
    fi
fi

mkdir -p ./data
chmod -R u+rwX ./data

echo "Please provide URL, path to users.json, or press Enter to skip:"
read -r users_json_source

if [[ "$users_json_source" == http* ]]; then
    mkdir -p data
    download_with_retries "$users_json_source" "data/users.json"
elif [ -n "$users_json_source" ]; then
    if [ -f "$users_json_source" ]; then
        mkdir -p data
        cp "$users_json_source" data/users.json || { log_error "Failed to copy users.json"; exit 1; }
        echo "users.json copied successfully from $users_json_source"
    else
        log_error "File not found: $users_json_source"
        exit 1
    fi
fi

mkdir -p ./data
chmod -R u+rwX ./data

mkdir -p /data/data/com.termux/files/usr/var/log/

edit_file() {
    local file_path="$1"
    if [ ! -f "$file_path" ]; then
        echo "File not found: $file_path"
        return 1
    fi

    termux-open "$file_path"

    echo "File opened in external editor. Press Enter when you're done editing."
    read -r
}

edit_zeronet_file() {
    echo "Select a file to edit:"
    echo "1) content.json"
    echo "2) index.html"
    echo "3) Other file (specify path)"
    read -p "Enter your choice: " choice

    case $choice in
        1) edit_file "$ZERONET_DIR/data/1HeLLo4uzjaLetFx6NH3PMwFP3qbRbTf3D/content.json" ;;
        2) edit_file "$ZERONET_DIR/data/1HeLLo4uzjaLetFx6NH3PMwFP3qbRbTf3D/index.html" ;;
        3) 
            read -p "Enter the relative path of the file: " rel_path
            edit_file "$ZERONET_DIR/data/$rel_path"
            ;;
        *) echo "Invalid choice" ;;
    esac
}

update_trackers() {
    echo "Updating trackers list..."
    TRACKERS_FILE="$ZERONET_DIR/data/trackers.json"
    trackers_urls=(
        "https://cf.trackerslist.com/best.txt"
        "https://bitbucket.org/xiu2/trackerslistcollection/raw/master/best.txt"
        "https://cdn.jsdelivr.net/gh/XIU2/TrackersListCollection/best.txt"
        "https://fastly.jsdelivr.net/gh/XIU2/TrackersListCollection/best.txt"
        "https://gcore.jsdelivr.net/gh/XIU2/TrackersListCollection/best.txt"
        "https://cdn.statically.io/gh/XIU2/TrackersListCollection/best.txt"
        "https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/best.txt"
    )
    mkdir -p "$(dirname "$TRACKERS_FILE")"

    while true; do
        for tracker_url in "${trackers_urls[@]}"; do
            echo "Attempting to download tracker list from $tracker_url..."
            if curl -s -f "$tracker_url" -o "$TRACKERS_FILE"; then
                echo "Successfully downloaded tracker list from $tracker_url"
                return
            else
                echo "Failed to download from $tracker_url."
            fi
        done
        echo "Failed to download from any URL. Retrying in 5 seconds..."
        sleep 5
    done
}

configure_tor() {
    echo "Configuring Tor..."
    mkdir -p $HOME/.tor
    mkdir -p /data/data/com.termux/files/usr/var/log/tor
    mkdir -p /data/data/com.termux/files/home/.tor/ZeroNet

    cat > $HOME/.tor/torrc << EOL
SocksPort 49050
ControlPort 49051
CookieAuthentication 1
HiddenServiceDir /data/data/com.termux/files/home/.tor/ZeroNet
HiddenServicePort 8008 127.0.0.1:$FILESERVER_PORT
HiddenServiceVersion 3
Log notice file /data/data/com.termux/files/usr/var/log/tor/notices.log
EOL
    echo "Tor configuration created at $HOME/.tor/torrc"
}
echo "Setting up Tor..."
configure_tor

echo "Starting Tor service..."
tor -f $HOME/.tor/torrc &
TOR_PID=$!

echo "Waiting for Tor to start and generate the hidden service..."
sleep 60

# Simple check to see if Tor is still running
if kill -0 $TOR_PID 2>/dev/null; then
    echo "Tor process is still running after 60 seconds. Proceeding with hidden service setup."
else
    echo "Tor process is not running. There may have been an issue starting Tor."
    exit 1
fi

echo "Retrieving onion address..."
if [ -f "/data/data/com.termux/files/home/.tor/hidden_service/hostname" ]; then
    ONION_ADDRESS=$(cat /data/data/com.termux/files/home/.tor/hidden_service/hostname)
    echo "Onion address: $ONION_ADDRESS"
else
    echo "Failed to retrieve onion address. Tor hidden service may not have been created properly."
    echo "Contents of the hidden service directory:"
    ls -la /data/data/com.termux/files/home/.tor/hidden_service
    echo "Last 20 lines of Tor log:"
    tail -n 20 /data/data/com.termux/files/usr/var/log/tor/notices.log
    exit 1
fi

echo "Setting up Tor..."
configure_tor

# After ZeroNet installation and configuration, but before starting Tor and ZeroNet:

BOOT_SCRIPT="$HOME/.termux/boot/start-zeronet"
mkdir -p "$HOME/.termux/boot"

echo "This script will create a Termux Boot script at: $BOOT_SCRIPT"
echo "The script will start ZeroNet automatically when your device boots."
echo ""
echo "IMPORTANT: For this to work, you need to have opened Termux:Boot at least once since the last fresh start of Termux."
echo ""
echo "Have you done this? (y/n)"
read -r boot_setup

if [[ $boot_setup =~ ^[Yy]$ ]]; then
    cat > "$BOOT_SCRIPT" << EOL
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock

ZERONET_DIR=/data/data/com.termux/files/home/apps/zeronet

start_tor() {
    tor &
    sleep 60
}

start_zeronet() {
    cd \$ZERONET_DIR
    . ./venv/bin/activate
    python zeronet.py --config_file \$ZERONET_DIR/zeronet.conf &
    
    ZERONET_PID=\$!
    echo "ZeroNet started with PID \$ZERONET_PID"
    termux-notification --title "ZeroNet Running" --content "ZeroNet started with PID \$ZERONET_PID" --ongoing
}

start_tor
start_zeronet
EOL

    chmod +x "$BOOT_SCRIPT"
    echo "Termux Boot script created at $BOOT_SCRIPT"
else
    echo "Please open Termux:Boot once since the last fresh start of Termux, then run this script again to set up auto-start."
fi

echo "Starting Tor service..."
tor &
TOR_PID=$!

echo "Waiting for Tor to start and bootstrap..."
sleep 60

# Simple check to see if Tor is still running
if kill -0 $TOR_PID 2>/dev/null; then
    echo "Tor process is still running after 60 seconds. Proceeding with ZeroNet startup."
else
    echo "Tor process is not running. There may have been an issue starting Tor."
    exit 1
fi

echo "Retrieving onion address..."
ONION_ADDRESS=$(cat /data/data/com.termux/files/home/.tor/hidden_service/hostname)
if [ -z "$ONION_ADDRESS" ]; then
    echo "Failed to retrieve onion address. Tor hidden service may not have been created properly."
    exit 1
fi
echo "Onion address: $ONION_ADDRESS"

# Start ZeroNet
start_zeronet

echo "Starting Tor service..."
tor &
TOR_PID=$!

echo "Waiting for Tor to start and bootstrap..."
sleep 60

# Simple check to see if Tor is still running
if kill -0 $TOR_PID 2>/dev/null; then
    echo "Tor process is still running after 60 seconds. Proceeding with ZeroNet startup."
else
    echo "Tor process is not running. There may have been an issue starting Tor."
    exit 1
fi

echo "Retrieving onion address..."
ONION_ADDRESS=$(cat /data/data/com.termux/files/home/.tor/hidden_service/hostname)
if [ -z "$ONION_ADDRESS" ]; then
    echo "Failed to retrieve onion address. Tor hidden service may not have been created properly."
    exit 1
fi
echo "Onion address: $ONION_ADDRESS"

create_zeronet_conf() {
    local conf_file="$ZERONET_DIR/zeronet.conf"
    
    # Read existing configuration for fileserver_port
    if [ -f "$conf_file" ]; then
        FILESERVER_PORT=$(grep -oP '(?<=fileserver_port = )\d+' "$conf_file")
    fi

    # If fileserver_port is not found, use a default
    if [ -z "$FILESERVER_PORT" ]; then
        FILESERVER_PORT=$(shuf -i 1024-65535 -n 1)
        echo "Generated random fileserver port: $FILESERVER_PORT"
    fi

    # Create new configuration with security settings
    cat > "$conf_file" << EOL
[global]
ui_ip = 127.0.0.1
ui_port = 43110
data_dir = $ZERONET_DIR/data
log_dir = /data/data/com.termux/files/usr/var/log/zeronet
tor_controller = 127.0.0.1:49051
tor_proxy = 127.0.0.1:49050
tor_use_bridge = False
trackers_file = $ZERONET_DIR/data/trackers.json
trackers_proxy = tor
proxy = tor
fileserver_port = $FILESERVER_PORT
ip_external = ${ONION_ADDRESS}:8008
fileserver_ip_type = ipv4
use_openssl = True
disable_udp = True
disable_encryption = False
trackers_file = $ZERONET_DIR/data/trackers.json
homepage = 191CazMVNaAcT9Y1zhkxd9ixMBPs59g2um
version_check = False
use_tempfiles = True
debug = False
offline = False
plugins = []
language = en
tor = always
EOL
    echo "ZeroNet configuration file updated at $conf_file with security settings"
}

# First, create the initial ZeroNet configuration to get a random port
create_zeronet_conf

# Now configure and start Tor
echo "Setting up Tor..."
configure_tor

echo "Starting Tor service..."
tor -f $HOME/.tor/torrc &
TOR_PID=$!

echo "Waiting for Tor to start and generate the hidden service..."
sleep 60

# Simple check to see if Tor is still running
if kill -0 $TOR_PID 2>/dev/null; then
    echo "Tor process is still running after 60 seconds. Proceeding with hidden service setup."
else
    echo "Tor process is not running. There may have been an issue starting Tor."
    echo "Last 20 lines of Tor log:"
    tail -n 20 /data/data/com.termux/files/usr/var/log/tor/notices.log
    exit 1
fi

# Update ZeroNet configuration with the onion address
create_zeronet_conf

echo "ZeroNet configuration has been updated with security settings and onion address."

BOOT_SCRIPT="$HOME/.termux/boot/start-zeronet"
mkdir -p "$HOME/.termux/boot"

echo "This script will create a Termux Boot script at: $BOOT_SCRIPT"
echo "The script will start ZeroNet automatically when your device boots."
echo ""
echo "IMPORTANT: For this to work, you need to have opened Termux:Boot at least once since the last fresh start of Termux."
echo ""
echo "Have you done this? (y/n)"
read -r boot_setup

if [[ $boot_setup =~ ^[Yy]$ ]]; then
    cat > "$BOOT_SCRIPT" << EOL
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock

ZERONET_DIR=/data/data/com.termux/files/home/apps/zeronet

start_tor() {
    tor -f $HOME/.tor/torrc &
    sleep 60
}

start_zeronet() {
    cd \$ZERONET_DIR
    . ./venv/bin/activate
    python zeronet.py --config_file \$ZERONET_DIR/zeronet.conf &
    
    ZERONET_PID=\$!
    echo "ZeroNet started with PID \$ZERONET_PID"
    termux-notification --title "ZeroNet Running" --content "ZeroNet started with PID \$ZERONET_PID" --ongoing
}

start_tor
start_zeronet
EOL

    chmod +x "$BOOT_SCRIPT"
    echo "Termux Boot script created at $BOOT_SCRIPT"
else
    echo "Please open Termux:Boot once since the last fresh start of Termux, then run this script again to set up auto-start."
fi

echo "Starting ZeroNet..."
start_zeronet() {
    update_trackers
    cd $ZERONET_DIR
    . ./venv/bin/activate
    
    # Rename disabled-Bootstrapper to Bootstrapper
    if [ -d "$ZERONET_DIR/plugins/disabled-Bootstrapper" ]; then
        mv "$ZERONET_DIR/plugins/disabled-Bootstrapper" "$ZERONET_DIR/plugins/Bootstrapper"
        echo "Renamed disabled-Bootstrapper to Bootstrapper"
    else
        echo "disabled-Bootstrapper directory not found"
    fi
    
    python zeronet.py --config_file $ZERONET_DIR/zeronet.conf &
    ZERONET_PID=$!
    echo "ZeroNet started with PID $ZERONET_PID"
    termux-notification --title "ZeroNet Running" --content "ZeroNet started with PID $ZERONET_PID" --ongoing
}

start_zeronet

if ! ps -p $ZERONET_PID > /dev/null; then
    log_error "Failed to start ZeroNet"
    termux-notification --title "ZeroNet Error" --content "Failed to start ZeroNet"
    exit 1
fi

view_log() {
    termux-dialog confirm -i "View last 50 lines of log?" -t "View Log"
    if [ $? -eq 0 ]; then
        LOG_CONTENT=$(tail -n 50 "/data/data/com.termux/files/usr/var/log/zeronet/debug.log")
        termux-dialog text -t "ZeroNet Log (last 50 lines)" -i "$LOG_CONTENT"
    fi
}

# Start ZeroNet briefly to generate config
cd $ZERONET_DIR && . ./venv/bin/activate
python zeronet.py --silent & 
TEMP_ZERONET_PID=$!; sleep 10; kill $TEMP_ZERONET_PID

# Read ZeroNet port
FILESERVER_PORT=$(grep -oP '(?<=fileserver_port = )\d+' "$ZERONET_DIR/zeronet.conf")
echo "ZeroNet port: $FILESERVER_PORT"

# Configure and start Tor
cat > $HOME/.tor/torrc << EOL
SocksPort 49050
ControlPort 49051
CookieAuthentication 1
HiddenServiceDir /data/data/com.termux/files/home/.tor/ZeroNet
HiddenServicePort 80 127.0.0.1:$FILESERVER_PORT
HiddenServiceVersion 3
Log notice file /data/data/com.termux/files/usr/var/log/tor/notices.log
EOL

tor -f $HOME/.tor/torrc &
TOR_PID=$!; sleep 60

# Update ZeroNet config with onion address
ONION_ADDRESS=$(cat /data/data/com.termux/files/home/.tor/ZeroNet/hostname)
sed -i "s/^ip_external = .*/ip_external = ${ONION_ADDRESS}/" "$ZERONET_DIR/zeronet.conf"

restart_zeronet() {
    termux-dialog confirm -i "Are you sure you want to restart ZeroNet?" -t "Restart ZeroNet"
    if [ $? -eq 0 ]; then
        echo "Restarting ZeroNet..."
        kill $ZERONET_PID
        start_zeronet
        echo "ZeroNet restarted with PID $ZERONET_PID"
        termux-notification --title "ZeroNet Restarted" --content "New PID: $ZERONET_PID"
    fi
}

LAST_CHECKED_TIME=0

get_zeronet_homepage() {
    # Use the ZeroNet Conservancy homepage address
    echo "191CazMVNaAcT9Y1zhkxd9ixMBPs59g2um"
}

HOMEPAGE_ADDRESS=$(get_zeronet_homepage)

check_for_new_content() {
    local content_json="$ZERONET_DIR/data/$HOMEPAGE_ADDRESS/content.json"
    if [ ! -f "$content_json" ]; then
        echo "content.json not found for ZeroNet Conservancy homepage. Skipping check."
        return
    fi

    local current_time=$(date +%s)
    local file_mod_time=$(stat -c %Y "$content_json")

    if [ $file_mod_time -gt $LAST_CHECKED_TIME ]; then
        echo "New content detected on ZeroNet Conservancy homepage. Checking for new posts..."
        local new_posts=$(python -c "
import json
with open('$content_json', 'r') as f:
    data = json.load(f)
posts = data.get('posts', [])
new_posts = [post for post in posts if post.get('date_added', 0) / 1000 > $LAST_CHECKED_TIME]
for post in new_posts[:5]:  # Limit to 5 newest posts
    print(f\"New post: {post.get('title', 'Untitled')}\")")

        if [ ! -z "$new_posts" ]; then
            echo "$new_posts"
            termux-notification --title "New ZeroNet Content" --content "$new_posts"
        fi
        LAST_CHECKED_TIME=$current_time
    else
        echo "No new content detected on ZeroNet Conservancy homepage."
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
    ACTION=$(termux-dialog sheet -v "Edit ZeroNet File,View Log,Restart ZeroNet,Check for New Content,Exit" -t "ZeroNet Management")
    case $ACTION in
        *"Edit ZeroNet File"*)
            edit_zeronet_file
            ;;
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
                echo "Stopping ZeroNet and exiting..."
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
