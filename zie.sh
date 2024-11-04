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
SYNCRONITE_ADDRESS="15CEFKBRHFfAP9rmL6hhLmHoXrrgmw4B5o"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
FILESERVER_PORT=43110

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

get_python_version() {
   python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
}

PYTHON_VERSION=$(get_python_version)
PYTHON_MAJOR_VERSION=${PYTHON_VERSION%.*}
PYTHON_MINOR_VERSION=${PYTHON_VERSION#*.}

log "Detected Python version: $PYTHON_VERSION"

echo "ZeroNet installation: Step 3 of 4 - Gathering information"

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
   clang make termux-api tor perl jq openssl-tool iproute2
   zlib
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
   if ! dpkg -s "$package" 2>&1; then
       install_package "$package" || exit 1
   fi
done

install_python_packages() {
   log "Installing required Python packages..."
   
   # Ensure Python is up to date
   pkg upgrade python

   export CFLAGS="-I$PREFIX/include -I$PREFIX/include/python$PYTHON_VERSION"
   export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib/python$PYTHON_VERSION/config-$PYTHON_VERSION"
   export PYTHONPATH="$PREFIX/lib/python$PYTHON_VERSION/site-packages"

   pip$PYTHON_MAJOR_VERSION install --upgrade pip setuptools wheel

   # Create our own requirements.txt file
   cat > "$WORK_DIR/custom_requirements.txt" << EOL
setuptools
greenlet
cffi
gevent
gevent-ws
PySocks
requests
GitPython
pycryptodome
pyOpenSSL
coincurve
pyasn1
rsa
msgpack
base58
merkletools
maxminddb
defusedxml
pyaes
ipython
EOL

   log "Installing Python packages individually..."
   while read -r package; do
       if pip$PYTHON_MAJOR_VERSION install "$package"; then
           log "Successfully installed $package"
       else
           log_error "Failed to install $package"
           return 1
       fi
   done < "$WORK_DIR/custom_requirements.txt"

   if [ $? -eq 0 ]; then
       log "Successfully installed all required Python packages"
   else
       log_error "Failed to install some Python packages from custom_requirements.txt"
       return 1
   fi

   # Verify installations
   log "Verifying installations..."
   python$PYTHON_MAJOR_VERSION -c "import gevent; from Crypto.Hash import SHA3_256; import OpenSSL; print('SHA3-256:', SHA3_256.new(b'test').hexdigest()); print('All required Python packages successfully installed')" || log_error "Failed to import one or more required Python packages"
}

if [ -d "$ZERONET_DIR" ] && [ "$(ls -A "$ZERONET_DIR")" ]; then
   log "The directory $ZERONET_DIR already exists and is not empty."
   log "Proceeding to adjust permissions and clean the directory."
   chmod -R u+rwX "$ZERONET_DIR" || { log_error "Failed to adjust permissions on existing directory"; exit 1; }
   rm -rf "$ZERONET_DIR" || { log_error "Failed to remove existing directory"; exit 1; }
fi

mkdir -p "$ZERONET_DIR"

cd "$WORK_DIR" || { log_error "Failed to change to working directory"; exit 1; }

git_clone_with_retries() {
   local repo_url=$1
   local target_dir=$2
   local branch=$3

   while true; do
       log "Attempting to clone $repo_url..."
       if git clone --depth 1 --branch "$branch" "$repo_url" "$target_dir"; then
           log "Successfully cloned $repo_url"
           break
       else
           log "Failed to clone $repo_url. Retrying in 5 seconds..."
           rm -rf "$target_dir"
           sleep 5
       fi
   done
}

zeronet_source="https://github.com/zeronet-conservancy/zeronet-conservancy.git"
git_clone_with_retries "$zeronet_source" "$ZERONET_DIR" "optional-rich-master"

cd "$ZERONET_DIR" || exit 1

# Check for key files
if [ ! -f "$ZERONET_DIR/zeronet.py" ]; then
  log_error "zeronet.py not found. ZeroNet installation might be incomplete."
  exit 1
fi

# Check if src directory exists
if [ -d "$ZERONET_DIR/src" ]; then
  sed -i '1i import traceback' "$ZERONET_DIR/src/util/Git.py"
else
  log "src directory not found. Checking alternative structure..."
  if [ -f "$ZERONET_DIR/util/Git.py" ]; then
      sed -i '1i import traceback' "$ZERONET_DIR/util/Git.py"
  else
      log_error "Unable to locate Git.py. ZeroNet structure might have changed."
      exit 1
  fi
fi

if [ ! -d "$ZERONET_DIR/venv" ]; then
  python$PYTHON_MAJOR_VERSION -m venv "$ZERONET_DIR/venv"
fi

source "$ZERONET_DIR/venv/bin/activate"

# Check if requirements.txt exists
if [ -f "$ZERONET_DIR/requirements.txt" ]; then
  pip install -r "$ZERONET_DIR/requirements.txt"
else
  log "requirements.txt not found. Installing packages from custom list..."
  # Install packages from our custom list
  install_python_packages
fi

chmod -R u+rwX "$ZERONET_DIR"

mkdir -p ./data
chmod -R u+rwX ./data

if [[ "$users_json_source" == http* ]]; then
  mkdir -p data
  curl -L "$users_json_source" -o "data/users.json"
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

mkdir -p $PREFIX/var/log/

update_zeronet_conf() {
   log "Updating ZeroNet configuration..."
   local conf_file="$ZERONET_DIR/zeronet.conf"

   # Create or update the configuration file
   cat > "$conf_file" << EOL
[global]
data_dir = $ZERONET_DIR/data
log_dir = $PREFIX/var/log/zeronet
ui_ip = 127.0.0.1
ui_port = $FILESERVER_PORT
tor_controller = $TOR_CONTROL_PORT
tor_proxy = $TOR_PROXY_PORT
language = en
tor = enable
fileserver_port = $FILESERVER_PORT
EOL

   if [[ $onion_tracker_setup =~ ^[Yy]$ ]] && [ -n "$ONION_ADDRESS" ]; then
       echo "ip_external = $ONION_ADDRESS" >> "$conf_file"
   else
       echo "ip_external = " >> "$conf_file"
   fi

   log "ZeroNet configuration updated at $conf_file"
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

export PATH=$PATH:/data/data/com.termux/files/usr/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/data/data/com.termux/files/usr/lib

start_tor() {
  tor -f "/data/data/com.termux/files/home/.tor/torrc" &
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
  python zeronet.py --debug &

  ZERONET_PID=$!
  echo "ZeroNet started"
  termux-notification --id "zeronet_status" --title "ZeroNet Running" --content "ZeroNet started" --ongoing
  termux-notification --id "zeronet_url" --title "ZeroNet URL" --content "http://127.0.0.1:$FILESERVER_PORT" --button1 "Copy" --button1-action "termux-clipboard-set 'http://127.0.0.1:$FILESERVER_PORT'"
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
  if command -v openssl; then
      log "OpenSSL is available. Version: $(openssl version)"
  else
      log_error "OpenSSL is not found in PATH. Please ensure it's installed."
      exit 1
  fi
}

start_zeronet() {
  cd $ZERONET_DIR || { log_error "Failed to change to ZeroNet directory"; return 1; }
  source ./venv/bin/activate || { log_error "Failed to activate virtual environment"; return 1; }

  # Add Termux bin to PATH
  export PATH=$PATH:$PREFIX/bin

  # Check for existing ZeroNet processes
  if pgrep -f "python.*zeronet.py" > /dev/null; then
      log "Existing ZeroNet process found. Terminating..."
      pkill -f "python.*zeronet.py"
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

  # Start ZeroNet with the updated PATH and debug output
  log "Starting ZeroNet..."
  python$PYTHON_MAJOR_VERSION zeronet.py --debug > zeronet_debug.log 2>&1 &
  ZERONET_PID=$!
  
  # Wait for process to start
  sleep 5
  
  if ! ps -p $ZERONET_PID > /dev/null; then
      log "ZeroNet process failed to start. Debug log follows:"
      cat zeronet_debug.log
      return 1
  fi

  log "ZeroNet started with PID $ZERONET_PID"

  # Wait for ZeroNet to initialize
  local counter=0
  local max_wait=60  # Wait up to 60 seconds for initialization
  
  while [ $counter -lt $max_wait ]; do
      if grep -q "Web interface: http://127.0.0.1:$FILESERVER_PORT" zeronet_debug.log; then
          log "ZeroNet initialized successfully"
          return 0
      fi
      sleep 1
      ((counter++))
  done

  if [ $counter -ge $max_wait ]; then
      log "ZeroNet initialization timed out. Debug log follows:"
      cat zeronet_debug.log
      return 1
  fi
}

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

download_geoip_database

check_openssl

# Initial run to generate files and initialize
log "Initial ZeroNet startup..."
if ! start_zeronet; then
   log_error "Initial ZeroNet startup failed"
   exit 1
fi

# Update configuration
update_zeronet_conf

# Start ZeroNet with new configuration
log "Starting ZeroNet with updated configuration..."
if ! start_zeronet; then
   log_error "Failed to start ZeroNet with new configuration"
   exit 1
fi

termux-notification --id "zeronet_status" --title "ZeroNet Running" --content "ZeroNet started with new configuration" --ongoing
termux-notification --id "zeronet_url" --title "ZeroNet URL" --content "http://127.0.0.1:$FILESERVER_PORT" --button1 "Copy" --button1-action "termux-clipboard-set 'http://127.0.0.1:$FILESERVER_PORT'"

log "ZeroNet started. Waiting 10 seconds before further operations..."
sleep 10

download_syncronite() {
  log "Downloading Syncronite content..."
  ZIP_URL="https://0net-preview.com/ZeroNet-Internal/Zip?address=$SYNCRONITE_ADDRESS"
  ZIP_DIR="$ZERONET_DIR/data/$SYNCRONITE_ADDRESS"

  mkdir -p "$ZIP_DIR"
  while true; do
      if curl -L "$ZIP_URL" -o "$ZIP_DIR/content.zip"; then
          unzip -o "$ZIP_DIR/content.zip" -d "$ZIP_DIR"
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
1. Visit http://127.0.0.1:$FILESERVER_PORT/$SYNCRONITE_ADDRESS
2. ZeroNet will add Syncronite to your dashboard.
Note: Only open links to ZeroNet sites that you trust."
  
  log_and_show "To add Syncronite to your ZeroNet:"
  log_and_show "1. Open this link in your web browser: http://127.0.0.1:$FILESERVER_PORT/$SYNCRONITE_ADDRESS"
  log_and_show "2. ZeroNet will automatically add Syncronite to your dashboard when you visit the link."
  log_and_show "Note: Only open links to ZeroNet sites that you trust."
  
  termux-notification --id "syncronite_url" --title "Syncronite URL" --content "http://127.0.0.1:$FILESERVER_PORT/$SYNCRONITE_ADDRESS" --button1 "Copy" --button1-action "termux-clipboard-set 'http://127.0.0.1:$FILESERVER_PORT/$SYNCRONITE_ADDRESS'"
  
  termux-notification --id "syncronite_instructions" --title "Syncronite Instructions" --content "$instructions"
}

if download_syncronite; then
  log "Syncronite content is now available in your ZeroNet data directory."
else
  log_error "Failed to prepare Syncronite content. You may need to add it manually later."
fi

log_and_show "ZeroNet setup complete."

# Verify ZeroNet is running
if ! pgrep -f "python.*zeronet.py" > /dev/null; then
  log_error "Failed to start ZeroNet"
  termux-notification --id "zeronet_error" --title "ZeroNet Error" --content "Failed to start ZeroNet"
  exit 1
fi

log_and_show "ZeroNet is running successfully. Syncronite content is available."

# Clean up
rm -rf "$WORK_DIR"

log_and_show "ZeroNet installation completed successfully!"
log_and_show "You can now access ZeroNet at http://127.0.0.1:$FILESERVER_PORT"

log "Installation process completed. Please review the log file at $LOG_FILE for details."

# Provide instructions for adding Syncronite
provide_syncronite_instructions

# Final message
log_and_show "Thank you for installing ZeroNet. Enjoy your decentralized web experience!"
