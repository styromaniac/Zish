#!/data/data/com.termux/files/usr/bin/bash

# Ensure we're in the right directory
cd "$(dirname "$0")"

# Check if Python is installed
if ! command -v python &> /dev/null; then
    echo "Python is not installed. Installing Python..."
    pkg install python -y
fi

# Run the Python server
python server.py
