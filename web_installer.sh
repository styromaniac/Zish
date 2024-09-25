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
pkg install -y python python-pip curl || log_error "Failed to install required packages"

log "Ensuring temporary directory exists..."
mkdir -p "$PREFIX/tmp" || log_error "Failed to create temporary directory"

log "Environment setup complete. Starting web installer..."

# Web installer part
python - << END
import http.server
import socketserver
import urllib.parse
import subprocess
import threading
import json
import os
import tempfile

ZI_SH_URL = "https://raw.githubusercontent.com/styromaniac/Zish/refs/heads/main/zi.sh"

# Determine a writable temporary directory
temp_dir = tempfile.gettempdir()
install_progress_path = os.path.join(temp_dir, 'install_progress')

class InstallerHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/':
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            with open('installer.html', 'rb') as file:
                self.wfile.write(file.read())
        elif self.path == '/status':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            try:
                with open(install_progress_path, 'r') as f:
                    content = f.read().strip()
            except FileNotFoundError:
                content = "Waiting to start installation..."
            self.wfile.write(json.dumps({'status': content}).encode())
        else:
            self.send_error(404)

    def do_POST(self):
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length).decode('utf-8')
        params = urllib.parse.parse_qs(post_data)

        # Start installation in a separate thread
        threading.Thread(target=self.install_zeronet, args=(params,)).start()

        self.send_response(200)
        self.send_header('Content-type', 'text/plain')
        self.end_headers()
        self.wfile.write(b"Installation started")

    def install_zeronet(self, params):
        with open(install_progress_path, 'w') as f:
            f.write("STATUS:Downloading zi.sh...\n")

        # Download zi.sh
        result = subprocess.run(["curl", "-fsSL", ZI_SH_URL, "-o", "zi.sh"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)

        if result.returncode != 0:
            with open(install_progress_path, 'w') as f:
                f.write(f"STATUS:Failed to download zi.sh. Error: {result.stderr}\n")
            return

        inputs = f"{params['zeronet_source'][0]}\\n{params['users_json'][0]}\\n{params['onion_tracker'][0]}\\n{params['boot_setup'][0]}\\n"
        command = f"bash -c 'source ./zi.sh && main' <<< '{inputs}'"
        process = subprocess.Popen(command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)

        for line in process.stdout:
            with open(install_progress_path, 'w') as f:
                f.write(line)
        
        for line in process.stderr:
            with open(install_progress_path, 'a') as f:  # Append stderr
                f.write(f"ERROR: {line}")

        process.wait()
        if process.returncode == 0:
            with open(install_progress_path, 'w') as f:
                f.write("STATUS:Installation complete!")
        else:
            with open(install_progress_path, 'w') as f:
                f.write(f"STATUS:Installation failed with return code {process.returncode}. Check logs for details.")

# Create HTML file
with open('installer.html', 'w') as f:
    f.write('''
    <!DOCTYPE html>
    <html>
    <head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <title>ZeroNet Installer</title>
        <style>
            body { font-family: Arial, sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; }
            input[type="text"] { width: 100%; padding: 5px; margin-bottom: 10px; }
            input[type="submit"] { background-color: #4CAF50; color: white; padding: 10px 20px; border: none; cursor: pointer; }
            #status { margin-top: 20px; padding: 10px; background-color: #f0f0f0; }
        </style>
        <script>
            function updateStatus() {
                fetch('/status')
                    .then(response => response.json())
                    .then(data => {
                        document.getElementById('status').innerText = data.status;
                    });
            }
            setInterval(updateStatus, 1000);
        </script>
    </head>
    <body>
        <h1>ZeroNet Installer</h1>
        <form method="post">
            <label for="zeronet_source">ZeroNet source URL or path:</label>
            <input type="text" id="zeronet_source" name="zeronet_source" required><br>
            <label for="users_json">users.json URL or path (optional):</label>
            <input type="text" id="users_json" name="users_json"><br>
            <label for="onion_tracker">Set up onion tracker? (y/n):</label>
            <input type="text" id="onion_tracker" name="onion_tracker" required><br>
            <label for="boot_setup">Set up auto-start with Termux:Boot? (y/n):</label>
            <input type="text" id="boot_setup" name="boot_setup" required><br>
            <input type="submit" value="Install">
        </form>
        <div id="status">Waiting to start installation...</div>
    </body>
    </html>
    ''')

# Start server
PORT = 8000
Handler = InstallerHandler

with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    print(f"Server started at http://127.0.0.1:{PORT}")
    print("Use 'termux-open-url http://127.0.0.1:8000' to open in browser")
    print("Press Ctrl+C to stop the server")
    httpd.serve_forever()
END
