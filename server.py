import http.server
import socketserver
import json
import subprocess
import threading
import time
import os

PORT = 8000
progress = 0
status_message = "Waiting to start..."
installation_complete = False

class RequestHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/':
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            with open('index.html', 'rb') as file:
                self.wfile.write(file.read())
        elif self.path == '/progress':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                "progress": progress,
                "status": status_message,
                "complete": installation_complete
            }).encode())
        else:
            super().do_GET()

    def do_POST(self):
        if self.path == '/start_installation':
            global progress, status_message, installation_complete
            progress = 0
            status_message = "Starting installation..."
            installation_complete = False
            threading.Thread(target=run_installation).start()
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"status": "started"}).encode())

def run_installation():
    global progress, status_message, installation_complete
    
    os.chmod('zi.sh', 0o755)
    
    process = subprocess.Popen(['./zi.sh'], 
                               stdout=subprocess.PIPE, 
                               stderr=subprocess.STDOUT,
                               universal_newlines=True)

    for line in process.stdout:
        if "ERROR" in line:
            status_message = f"Error: {line.strip()}"
            break
        else:
            status_message = line.strip()
            progress += 1
        time.sleep(0.1)

    process.wait()
    if process.returncode == 0:
        status_message = "Installation completed successfully!"
        progress = 100
    else:
        status_message = f"Installation failed with return code {process.returncode}"
    
    installation_complete = True

if __name__ == "__main__":
    with socketserver.TCPServer(("127.0.0.1", PORT), RequestHandler) as httpd:
        print(f"Serving at http://127.0.0.1:{PORT}")
        httpd.serve_forever()
