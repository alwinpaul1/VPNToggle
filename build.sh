#!/bin/zsh
# Builds VPNToggle.app and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
APP=build/VPNToggle.app
rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
# App icon from icon/icon.svg (needs rsvg-convert: brew install librsvg)
ICONSET=build/AppIcon.iconset && mkdir -p $ICONSET
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s icon/icon.svg -o $ICONSET/icon_${s}x${s}.png
  rsvg-convert -w $((s*2)) -h $((s*2)) icon/icon.svg -o $ICONSET/icon_${s}x${s}@2x.png
done
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns
swiftc -O main.swift -o $APP/Contents/MacOS/VPNToggle -framework Cocoa -framework ServiceManagement
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.alwinpaul.vpntoggle</string>
  <key>CFBundleName</key><string>VPNToggle</string>
  <key>CFBundleExecutable</key><string>VPNToggle</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.alwinpaul.vpntoggle</string>
    <key>CFBundleURLSchemes</key><array><string>vpntoggle</string></array>
  </dict></array>
</dict></plist>
PLIST
# A stable local identity keeps the Keychain "Always Allow" valid across rebuilds; ad-hoc otherwise.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk '/VPNToggle Local Signing/{print $2; exit}')
codesign --force --sign "${IDENTITY:--}" $APP
mkdir -p ~/Applications
rm -rf ~/Applications/VPNToggle.app
cp -R $APP ~/Applications/
echo "Installed ~/Applications/VPNToggle.app"
