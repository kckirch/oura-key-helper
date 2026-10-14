#!/bin/bash
set -euo pipefail
# Explicit developer/user setup; the GUI never downloads dependencies silently.
python_binary="${OURA_HELPER_PYTHON:-python3}"
runtime_dir="$HOME/Library/Application Support/Oura Key Helper/USB Runtime"
"$python_binary" -m venv "$runtime_dir"
"$runtime_dir/bin/python3" -m pip install --no-cache-dir  -r "$(dirname "$0")/requirements-usb.lock"
