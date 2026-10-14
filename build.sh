#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app_dir="${OURA_HELPER_OUTPUT_DIR:-$PWD/dist}/Oura Key Helper.app"
while read -r pid; do
  [[ -z "$pid" ]] && continue
  running_command="$(ps -p "$pid" -o command=)"
  if [[ "$running_command" == "$app_dir/Contents/MacOS/OuraKeyHelper" ]]; then
    printf '%s\n' 'Quit the target app before rebuilding. Never replace a running app executable.' >&2
    exit 1
  fi
done < <(pgrep -x OuraKeyHelper || true)
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/Source"
cp "$binary_dir/OuraKeyHelper" "$app_dir/Contents/MacOS/OuraKeyHelper"
strip -S "$app_dir/Contents/MacOS/OuraKeyHelper"
cp Package.swift README.md LICENSE LICENSE-GPL-3.0 THIRD-PARTY.md PRODUCT.md DESIGN.md build.sh "$app_dir/Contents/Resources/Source/"
/usr/bin/rsync -a --exclude=__pycache__ Sources Tests Scripts "$app_dir/Contents/Resources/Source/"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Oura Key Helper</string>
<key>CFBundleDisplayName</key><string>Oura Key Helper</string>
<key>CFBundleIdentifier</key><string>com.kck.openoura.key-helper</string>
<key>CFBundleExecutable</key><string>OuraKeyHelper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.3</string>
<key>CFBundleVersion</key><string>12</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ ! -x build-usb/oura-usb/oura-usb ]]; then
  printf '%s\n' 'Build the bundled USB component first: bash Scripts/build-usb.sh' >&2
  exit 1
fi
mkdir -p "$app_dir/Contents/Resources/USB"
/usr/bin/rsync -a --delete build-usb/oura-usb/ "$app_dir/Contents/Resources/USB/"
cp build-usb-source/GPL-dependency-sources.tar.gz "$app_dir/Contents/Resources/Source/"
codesign --force --deep --sign - "$app_dir"
ditto -c -k --keepParent "$app_dir" "$(dirname "$app_dir")/Oura-Key-Helper-macOS.zip"
printf '%s\n' "$app_dir"
