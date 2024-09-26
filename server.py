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
current_prompt = None
user_responses = {}

PROMPTS = [
    "Please provide the Git clone URL or path to the ZeroNet source code archive (Git URL, .zip, or .tar.gz):",
    "Please provide URL, path to users.json, or press Enter to skip:",
    "Do you want to set up an onion tracker? This will strengthen ZeroNet. (y/n)",
    "Do you want to set up auto-start with Termux:Boot? (y/n)"
]

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
                "complete": installation_complete,
                "current_prompt": current_prompt
            }).encode())
        else:
            super().do_GET()

    def do_POST(self):
        if self.path == '/start_installation':
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            user_responses.update(json.loads(post_data.decode()))
            
            global current_prompt
            if len(user_responses) < len(PROMPTS):
                current_prompt = PROMPTS[len(user_responses)]
                response = {"status": "next_prompt", "prompt": current_prompt}
            else:
                current_prompt = None
                threading.Thread(target=run_installation).start()
                response = {"status": "started"}
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())

def run_installation():
    global progress, status_message, installation_complete
    
    # Prepare the responses for zi.sh
    responses = "\n".join(user_responses.values()) + "\n"
    
    process = subprocess.Popen(['./zi.sh'], 
                               stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, 
                               stderr=subprocess.STDOUT,
                               universal_newlines=True)

    # Send user responses to zi.sh
    process.stdin.write(responses)
    process.stdin.close()

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
