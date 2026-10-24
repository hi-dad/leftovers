#!/bin/zsh
# Builds Leftovers.app, installs it to /Applications and relaunches it.
# Needs only the Swift toolchain; no Xcode project.
#   ./build.sh          build + install + relaunch
#   ./build.sh dist     build dist/Leftovers.dmg to share (doesn't install); GitHub builds this on every push
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
  <key>NSDesktopFolderUsageDescription</key><string>Leftovers checks whether Claude's build folders on your Desktop are what Spotlight or cloud sync is busy with. It only looks at folder dates.</string>
  <key>NSHumanReadableCopyright</key><string>Free and offline.</string>
</dict></plist>
PLIST

# Signing: a stable certificate lets macOS remember Leftovers' permissions (Desktop folder) across rebuilds.
# Uses, in order: $SIGN_IDENTITY, the name in a local .signing-identity file (git-ignored, yours only),
# your first valid code-signing certificate (e.g. Xcode's "Apple Development"), or ad-hoc signing.
IDENTITY="${SIGN_IDENTITY:-}"
[[ -z "$IDENTITY" && -f .signing-identity ]] && IDENTITY="$(head -1 .signing-identity)"
[[ -z "$IDENTITY" ]] && IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/{print $2; exit}')"
# A Developer ID signature (GitHub's release builds) also gets the hardened runtime + timestamp Apple's notarization needs.
EXTRA=()
[[ "$IDENTITY" == "Developer ID Application"* ]] && EXTRA=(--options runtime --timestamp)
if [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" $EXTRA $APP 2>/dev/null; then
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - $APP
  echo "Signed ad-hoc (no certificate found); macOS may ask for permissions again after each rebuild."
fi

# ./build.sh dist: a disk image to share (the app + an Applications shortcut + install steps), no install.
if [[ "$1" == "dist" ]]; then
  rm -rf dist && mkdir -p dist/stage
  mv $APP dist/stage/
  ln -s /Applications dist/stage/Applications
  cp "How to install.txt" dist/stage/
  hdiutil create -volname "Leftovers" -srcfolder dist/stage -ov -format UDZO dist/Leftovers.dmg >/dev/null
  rm -rf dist/stage
  echo "Made dist/Leftovers.dmg"
  exit 0
fi

pkill -x Leftovers || true
while pgrep -x Leftovers >/dev/null; do sleep 0.2; done   # let it quit before relaunching
rm -rf /Applications/$APP
mv $APP /Applications/
# macOS can take a moment to register the new copy; retry the launch a few times.
for i in 1 2 3 4 5; do open /Applications/$APP 2>/dev/null && break; sleep 1; done
echo "Installed to /Applications"
