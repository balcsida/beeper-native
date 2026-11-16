#!/bin/sh
# Builds "build/Beeper Native.app". Notifications and a prompt-free Keychain need a signed bundle, which `swift run` is not.
set -eu
cd "$(dirname "$0")"
swift build -c release
app="build/Beeper Native.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/BeeperNative "$app/Contents/MacOS/"
cp AppIcon.icns "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.balcsida.BeeperNative</string>
    <key>CFBundleName</key><string>Beeper Native</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleExecutable</key><string>BeeperNative</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# A real identity keeps the Keychain grant across rebuilds; ad-hoc ("-") asks again every time.
identity="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk 'NR==1 && $2 ~ /^[0-9A-F]{40}$/ {print $2}')}"
codesign --force --sign "${identity:--}" "$app"
echo "Built $app"
