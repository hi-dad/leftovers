# Sparkle: lets the app update itself from this repo's GitHub releases.
# Sourced by the build script (and by the release step on GitHub). Works in bash and zsh.
#
# How it fits together: the app checks appcast.xml (published next to each release's DMG)
# about once a day; if its build number is higher, Sparkle offers to install it. Each DMG is
# signed with the Sparkle key (GitHub secret SPARKLE_ED_KEY), and the app only accepts updates
# that match the public key below.

SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
SPARKLE_PUBLIC_KEY="K7++3NVYizxiK9zTznBpBxkldMue0Uo9tI5lxwODJI4="
# Downloaded once per Mac and shared by builds.
SPARKLE_DIR="$HOME/Library/Caches/Sparkle-$SPARKLE_VERSION"
# Build number = how many commits are in the history, so it goes up with every change and the
# same code always gets the same number. Sparkle compares it to decide what's an update.
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
# Extra swiftc flags to compile and link against Sparkle.
SPARKLE_SWIFTC_FLAGS=(-F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)

# Fetch Sparkle's official release (checked against its known checksum) if it isn't here yet.
sparkle_fetch() {
  [[ -d "$SPARKLE_DIR/Sparkle.framework" && -x "$SPARKLE_DIR/bin/sign_update" ]] && return 0
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  echo "$SPARKLE_SHA256  $tmp/sparkle.tar.xz" | shasum -a 256 -c >/dev/null
  rm -rf "$SPARKLE_DIR" && mkdir -p "$SPARKLE_DIR"
  tar -xf "$tmp/sparkle.tar.xz" -C "$SPARKLE_DIR" Sparkle.framework bin/sign_update
  rm -rf "$tmp"
}

# Put Sparkle inside the app ($1). Its XPC services are only for sandboxed apps, so they're left out.
sparkle_embed() {
  mkdir -p "$1/Contents/Frameworks"
  rm -rf "$1/Contents/Frameworks/Sparkle.framework"
  ditto "${2:-$SPARKLE_DIR/Sparkle.framework}" "$1/Contents/Frameworks/Sparkle.framework"
  rm -rf "$1/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$1/Contents/Frameworks/Sparkle.framework/XPCServices"
}

# Add the build number and update settings to the app's ($1) Info.plist; $2 = GitHub repo name.
sparkle_plist() {
  local plist="$1/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$plist"
  plutil -replace SUFeedURL -string "https://github.com/hi-dad/$2/releases/latest/download/appcast.xml" "$plist"
  plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$plist"
  plutil -replace SUEnableAutomaticChecks -bool YES "$plist"
}

# Sign Sparkle's parts inside the app ($1), inside out, before the app itself is signed.
# The rest of the arguments are the codesign options (identity etc.); no entitlements here.
sparkle_sign() {
  local spk="$1/Contents/Frameworks/Sparkle.framework"
  shift
  codesign "$@" "$spk/Versions/B/Autoupdate"
  codesign "$@" "$spk/Versions/B/Updater.app"
  codesign "$@" "$spk"
}

# On GitHub, after notarizing: write dist/appcast.xml for the DMG ($1) of the app named $2 in
# repo $3, released under tag $4. Release notes = this commit's message.
sparkle_appcast() {
  local dmg="$1" name="$2" repo="$3" tag="$4" mount app
  [[ -n "$SPARKLE_ED_KEY" ]] || { echo "SPARKLE_ED_KEY isn't set" >&2; return 1; }
  sparkle_fetch
  for _ in 1 2 3 4 5; do  # hdiutil is sometimes briefly busy
    mount="$(hdiutil attach -nobrowse -readonly "$dmg" 2>/dev/null | awk -F'\t' '/Volumes/{print $NF}')"
    [[ -n "$mount" ]] && break
    sleep 3
  done
  [[ -n "$mount" ]] || { echo "Couldn't open $dmg" >&2; return 1; }
  app="$(ls -d "$mount"/*.app | head -1)"
  VERSION="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" \
  BUILD="$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")" \
  MINOS="$(plutil -extract LSMinimumSystemVersion raw "$app/Contents/Info.plist")" \
  ENCLOSURE="$(echo "$SPARKLE_ED_KEY" | "$SPARKLE_DIR/bin/sign_update" --ed-key-file - "$dmg")" \
  URL="https://github.com/hi-dad/$repo/releases/download/$tag/$(basename "$dmg")" \
  NAME="$name" NOTES="$(git log -1 --format=%B)" OUT="$(dirname "$dmg")/appcast.xml" python3 - <<'PY'
import email.utils, os
from xml.sax.saxutils import escape
e = os.environ
paras = [" ".join(p.split()) for p in e["NOTES"].split("\n\n")]  # the commit message, unwrapped
notes = "".join(f"<p>{escape(p)}</p>" for p in paras if p and not p.startswith("Co-Authored-By"))
open(e["OUT"], "w").write(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>{escape(e['NAME'])}</title>
    <item>
      <title>{escape(e['NAME'])} {e['VERSION']} (build {e['BUILD']})</title>
      <pubDate>{email.utils.formatdate()}</pubDate>
      <sparkle:version>{e['BUILD']}</sparkle:version>
      <sparkle:shortVersionString>{e['VERSION']}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{e['MINOS']}</sparkle:minimumSystemVersion>
      <description>{escape(notes)}</description>
      <enclosure url="{e['URL']}" {e['ENCLOSURE']} type="application/octet-stream"/>
    </item>
  </channel>
</rss>
''')
PY
  local status=$?
  hdiutil detach "$mount" -quiet
  [[ $status == 0 ]] && grep -q "<sparkle:version>[0-9]" "$(dirname "$dmg")/appcast.xml" || { echo "Couldn't write appcast.xml" >&2; return 1; }
  cat "$(dirname "$dmg")/appcast.xml"
}
