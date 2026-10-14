#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python_binary="${OURA_HELPER_PYTHON:-$HOME/Library/Application Support/Oura Key Helper/USB Runtime/bin/python3}"
"$python_binary" -m PyInstaller --clean --noconfirm --onedir --name oura-usb --distpath build-usb --workpath .build/pyinstaller --specpath .build Scripts/filtered_backup.py
