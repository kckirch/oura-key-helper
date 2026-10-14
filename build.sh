#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if pgrep -x OuraKeyHelper >/dev/null; then
  printf '%s\n' 'Quit Oura Key Helper before rebuilding. Never replace a running app executable.' >&2
  exit 1
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
app_dir="$PWD/dist/Oura Key Helper.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/Source"
cp "$binary_dir/OuraKeyHelper" "$app_dir/Contents/MacOS/OuraKeyHelper"
strip -S "$app_dir/Contents/MacOS/OuraKeyHelper"
cp Package.swift README.md LICENSE PRODUCT.md DESIGN.md build.sh "$app_dir/Contents/Resources/Source/"
cp -R Sources Tests "$app_dir/Contents/Resources/Source/"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Oura Key Helper</string>
<key>CFBundleDisplayName</key><string>Oura Key Helper</string>
<key>CFBundleIdentifier</key><string>com.kck.openoura.key-helper</string>
<key>CFBundleExecutable</key><string>OuraKeyHelper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.3</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
ditto -c -k --keepParent "$app_dir" "$PWD/dist/Oura-Key-Helper-macOS.zip"
printf '%s\n' "$app_dir"
