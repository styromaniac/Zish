#!/data/data/com.termux/files/usr/bin/bash

set -e

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

log_error() {
    log "[ERROR] $1"
    exit 1
}

# Setup part
log "Setting up environment..."
pkg update -y || log_error "Failed to update packages"
pkg upgrade -y || log_error "Failed to upgrade packages"
pkg install -y python python-pip build-essential || log_error "Failed to install required packages"

# Use system pip to install Cython and Kivy
log "Installing Cython..."
python -m pip install Cython || log_error "Failed to install Cython"

log "Installing Kivy..."
CPPFLAGS="-I/data/data/com.termux/files/usr/include" LDFLAGS="-L/data/data/com.termux/files/usr/lib" python -m pip install kivy || log_error "Failed to install Kivy"

log "Environment setup complete. Starting Kivy installer..."

# Kivy installer part
python - << END
import os
import subprocess
import threading
from kivy.app import App
from kivy.uix.boxlayout import BoxLayout
from kivy.uix.button import Button
from kivy.uix.label import Label
from kivy.uix.textinput import TextInput
from kivy.uix.progressbar import ProgressBar
from kivy.clock import Clock

ZI_SH_URL = "https://raw.githubusercontent.com/styromaniac/Zish/refs/heads/main/zi.sh"

class ZeroNetInstallerApp(App):
    def build(self):
        self.layout = BoxLayout(orientation='vertical', padding=10, spacing=10)
        
        self.status_label = Label(text="Ready to install ZeroNet")
        self.layout.add_widget(self.status_label)
        
        self.progress_bar = ProgressBar(max=100, value=0)
        self.layout.add_widget(self.progress_bar)
        
        self.source_input = TextInput(hint_text="Enter ZeroNet source URL or path")
        self.layout.add_widget(self.source_input)
        
        self.users_json_input = TextInput(hint_text="Enter users.json URL or path (optional)")
        self.layout.add_widget(self.users_json_input)
        
        self.onion_tracker = TextInput(hint_text="Set up onion tracker? (y/n)")
        self.layout.add_widget(self.onion_tracker)
        
        self.boot_setup = TextInput(hint_text="Set up auto-start with Termux:Boot? (y/n)")
        self.layout.add_widget(self.boot_setup)
        
        self.install_button = Button(text="Install ZeroNet", on_press=self.start_installation)
        self.layout.add_widget(self.install_button)
        
        Clock.schedule_interval(self.check_progress, 1)
        
        return self.layout
    
    def start_installation(self, instance):
        self.install_button.disabled = True
        threading.Thread(target=self.run_installation).start()
    
    def run_installation(self):
        # Download zi.sh
        self.status_label.text = "Downloading zi.sh..."
        subprocess.run(["curl", "-fsSL", ZI_SH_URL, "-o", "zi.sh"])
        
        inputs = f"{self.source_input.text}\\n{self.users_json_input.text}\\n{self.onion_tracker.text}\\n{self.boot_setup.text}\\n"
        command = f"bash -c 'source ./zi.sh && main' <<< '{inputs}'"
        process = subprocess.Popen(command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        
        for line in process.stdout:
            if line.startswith("PROGRESS:"):
                progress = int(line.split(":")[1])
                Clock.schedule_once(lambda dt: setattr(self.progress_bar, 'value', progress))
            elif line.startswith("STATUS:"):
                status = line.split(":")[1].strip()
                Clock.schedule_once(lambda dt: setattr(self.status_label, 'text', status))
        
        process.wait()
        if process.returncode == 0:
            Clock.schedule_once(lambda dt: setattr(self.status_label, 'text', "Installation complete!"))
        else:
            Clock.schedule_once(lambda dt: setattr(self.status_label, 'text', "Installation failed. Check logs for details."))
        Clock.schedule_once(lambda dt: setattr(self.install_button, 'disabled', False))
    
    def check_progress(self, dt):
        try:
            with open('/tmp/install_progress', 'r') as f:
                content = f.read().strip()
                if content.startswith('PROGRESS:'):
                    progress = int(content.split(':')[1])
                    self.progress_bar.value = progress
                elif content.startswith('STATUS:'):
                    status = content.split(':')[1]
                    self.status_label.text = status
                elif content.startswith('ERROR:'):
                    error = content.split(':')[1]
                    self.status_label.text = f"Error: {error}"
                    self.install_button.disabled = False
        except FileNotFoundError:
            pass

if __name__ == '__main__':
    ZeroNetInstallerApp().run()
END
