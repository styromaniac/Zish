#!/data/data/com.termux/files/usr/bin/bash

set -e

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

log_error() {
    log "[ERROR] $1"
    exit 1
}

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

# Update package lists
log "Updating package lists..."
yes | pkg update || log_error "Failed to update package lists"

# Install required packages
required_packages=(
    python
    python-pip
    libjpeg-turbo
    libsdl2
    libsdl2-image
    libsdl2-mixer
    libsdl2-ttf
)

for package in "${required_packages[@]}"; do
    install_package "$package"
done

# Install Kivy
log "Installing Kivy..."
pip install kivy || log_error "Failed to install Kivy"

# Download the Kivy installer script
log "Downloading Kivy installer script..."
curl -fsSL https://raw.githubusercontent.com/styromaniac/Zish/refs/heads/main/kivy_installer.py -o kivy_installer.py || log_error "Failed to download Kivy installer script"

# Run the Kivy installer
log "Launching Kivy installer..."
python kivy_installer.py
