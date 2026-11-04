#!/bin/sh
# Builds dist/Sill.app from the SwiftPM target: a menu bar app with its own bundle id,
# so macOS lists "Sill" for permissions (Accessibility, Desktop, Downloads).
set -eu
cd "$(dirname "$0")/.."
# Universal: Apple silicon and Intel, built one at a time because a multi-arch build needs full Xcode.
swift build -c release
swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/intel
APP=dist/Sill.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/Sill .build/intel/x86_64-apple-macosx/release/Sill -output "$APP/Contents/MacOS/Sill"
cp brand/Sill.icns "$APP/Contents/Resources/Sill.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Sill</string>
  <key>CFBundleDisplayName</key><string>Sill</string>
  <key>CFBundleIdentifier</key><string>app.sill.mac</string>
  <key>CFBundleExecutable</key><string>Sill</string>
  <key>CFBundleIconFile</key><string>Sill</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDownloadsFolderUsageDescription</key><string>Sill keeps your downloads on its shelf so you can find them again.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Sill keeps your screenshots on its shelf so you can find them again.</string>
</dict>
</plist>
PLIST
# Ad-hoc signature: enough to run locally. Each rebuild changes it, so macOS asks for permissions again.
codesign --force --sign - "$APP"
echo "built $APP"
