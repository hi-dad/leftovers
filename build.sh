#!/bin/zsh
# Builds Leftovers.app, installs it to /Applications and relaunches it.
# Needs only the Swift toolchain; no Xcode project.
#   ./build.sh          build + install + relaunch
#   swift test          run the tests
set -e
cd "$(dirname "$0")"
APP=Leftovers.app

# Universal binary: Apple Silicon + Intel Macs.
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Leftovers

rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/Leftovers
cp assets/AppIcon.icns $APP/Contents/Resources/

cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Leftovers</string>
  <key>CFBundleDisplayName</key><string>Leftovers</string>
  <key>CFBundleIdentifier</key><string>com.danielryan.Leftovers</string>
  <key>CFBundleExecutable</key><string>Leftovers</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Free and offline.</string>
</dict></plist>
PLIST

# Same local certificate as your other apps, so macOS remembers notification permission across rebuilds.
if security find-certificate -c "Daniel Ryan Local Signing" >/dev/null 2>&1; then
  codesign --force --sign "Daniel Ryan Local Signing" $APP
else
  codesign --force --sign - $APP
fi

pkill -x Leftovers || true
rm -rf /Applications/$APP
mv $APP /Applications/
open /Applications/$APP
echo "Installed to /Applications"
