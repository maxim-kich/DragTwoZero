#!/bin/bash
# Disposable signed two-version Sparkle test. Never opens or replaces the installed app.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-success}"
case "$MODE" in success|success-off|download-cancel|staged-cancel|bad-archive|bad-feed|incompatible) ;; *) echo 'Unknown fixture mode' >&2; exit 1;; esac
swift package resolve
ROOT=$(mktemp -d "$PWD/.local/updater-${MODE}.XXXXXX")
KEY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/drag2-updater-key.XXXXXX")
chmod 700 "$KEY_DIR"
SERVER_PID=""
FIXTURE_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  if [ -n "$FIXTURE_PID" ]; then kill "$FIXTURE_PID" 2>/dev/null || true; wait "$FIXTURE_PID" 2>/dev/null || true; fi
  rm -rf "$KEY_DIR"
}
trap cleanup EXIT
SPARKLE="$PWD/.build/artifacts/sparkle/Sparkle"
FRAMEWORKS="$SPARKLE/Sparkle.xcframework/macos-arm64_x86_64"
IDENTITY="${DRAGTWOZERO_FIXTURE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)}"
test -n "$IDENTITY" || { echo 'A development signing identity is required for this local test.' >&2; exit 1; }
cat > "$KEY_DIR/keygen.swift" <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
try Data(key.publicKey.rawRepresentation.base64EncodedString().utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
SWIFT
swift "$KEY_DIR/keygen.swift" "$KEY_DIR/private" "$KEY_DIR/public"
chmod 600 "$KEY_DIR/private"
mkdir -p "$ROOT/installed" "$ROOT/release" "$ROOT/served"
python3 - "$ROOT" "$MODE" <<'PY' &
import functools, http.server, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
class Handler(http.server.SimpleHTTPRequestHandler):
    def copyfile(self, source, output):
        if sys.argv[2] != 'download-cancel':
            return super().copyfile(source, output)
        try:
            while chunk := source.read(16384):
                output.write(chunk)
                output.flush()
                time.sleep(0.02)
        except (BrokenPipeError, ConnectionResetError):
            pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(root / 'served')))
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
PY
SERVER_PID=$!
for attempt in {1..50}; do test ! -f "$ROOT/port" || break; sleep 0.1; done
BASE="http://127.0.0.1:$(cat "$ROOT/port")"
ID="com.maximkich.drag2-updater-fixture.$(uuidgen | tr '[:upper:]' '[:lower:]')"
# Compile the production module without its app entry point. Shared diagnostics
# reference capture state, so selecting only updater files can omit dependencies.
FIXTURE_SOURCES=()
for source in Sources/DragTwoZero/*.swift; do
  if [ "$(basename "$source")" != main.swift ]; then FIXTURE_SOURCES+=("$source"); fi
done
swiftc -O -target arm64-apple-macos13.0 -F "$FRAMEWORKS" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "${FIXTURE_SOURCES[@]}" scripts/updater-fixture/main.swift \
  -o "$ROOT/DragTwoZero"
for VERSION in 9.0.1 9.0.2; do
  if [ "$VERSION" = 9.0.1 ]; then LOCATION=installed; else LOCATION=release; fi
  APP="$ROOT/$LOCATION/Drag 2.0 Updater Fixture.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
  cp "$ROOT/DragTwoZero" "$APP/Contents/MacOS/DragTwoZero"
  ditto "$FRAMEWORKS/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
  python3 - "$APP" "$VERSION" "$ID" "$ROOT" "$BASE" "$MODE" <<'PY'
import pathlib, plistlib, sys
app, version, ident, root, base, mode = sys.argv[1:]
info = dict(CFBundleIdentifier=ident, CFBundleName='Drag 2.0 Updater Fixture', CFBundleExecutable='DragTwoZero',
            CFBundlePackageType='APPL', CFBundleVersion=version, CFBundleShortVersionString=version,
            LSMinimumSystemVersion='99.0' if mode == 'incompatible' and version == '9.0.2' else '13.0',
            LSUIElement=True, NSAppTransportSecurity=dict(NSAllowsArbitraryLoads=True),
            FixtureReport=root + '/events.txt', FixtureBaseURL=base, FixtureMode=mode, FixtureArchiveLength=0)
pathlib.Path(app + '/Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
  python3 scripts/configure-updater.py "$APP/Contents/Info.plist" "$KEY_DIR/public"
  /usr/libexec/PlistBuddy -c "Set SUFeedURL $BASE/appcast.xml" "$APP/Contents/Info.plist"
  ./scripts/sign-sparkle.sh "$APP" "$IDENTITY" development > "$ROOT/sign-$VERSION.log" 2>&1
  codesign --force --sign "$IDENTITY" "$APP"
done
ARCHIVE="$ROOT/served/Drag-2.0-v9.0.2-macOS-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/release/Drag 2.0 Updater Fixture.app" "$ARCHIVE"
"$SPARKLE/bin/generate_appcast" --ed-key-file "$KEY_DIR/private" --maximum-deltas 0 \
  --download-url-prefix "$BASE/" -o "$ROOT/served/appcast.xml" "$ROOT/served" > "$ROOT/feed-generation.log" 2>&1
"$SPARKLE/bin/sign_update" --ed-key-file "$KEY_DIR/private" --verify "$ROOT/served/appcast.xml"
if [ "$MODE" = bad-archive ]; then
  python3 - "$ARCHIVE" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
data = bytearray(path.read_bytes())
data[len(data) // 2] ^= 1  # Preserve the length to exercise signature verification.
path.write_bytes(data)
PY
fi
if [ "$MODE" = bad-feed ]; then
  python3 - "$ROOT/served/appcast.xml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
assert '<sparkle:shortVersionString>9.0.2</sparkle:shortVersionString>' in text
path.write_text(text.replace('<sparkle:shortVersionString>9.0.2</sparkle:shortVersionString>',
                             '<sparkle:shortVersionString>9.0.3</sparkle:shortVersionString>'))
PY
fi
OLD_APP="$ROOT/installed/Drag 2.0 Updater Fixture.app"
/usr/libexec/PlistBuddy -c "Set FixtureArchiveLength $(stat -f %z "$ARCHIVE")" "$OLD_APP/Contents/Info.plist"
codesign --force --sign "$IDENTITY" "$OLD_APP"
codesign --verify --deep --strict "$OLD_APP"
"$OLD_APP/Contents/MacOS/DragTwoZero" > "$ROOT/process.log" 2>&1 &
FIXTURE_PID=$!
for attempt in {1..180}; do
  if [ -f "$ROOT/events.txt" ]; then
    if rg -q '^FAIL' "$ROOT/events.txt"; then cat "$ROOT/events.txt"; exit 1; fi
    if rg -q '^SUCCESS' "$ROOT/events.txt"; then break; fi
  fi
  sleep 0.5
done
test -f "$ROOT/events.txt" && rg -q '^SUCCESS' "$ROOT/events.txt" || { cat "$ROOT/process.log"; echo "Fixture failed; evidence: $ROOT" >&2; exit 1; }
sleep 1
ACTUAL=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$OLD_APP/Contents/Info.plist")
if [[ "$MODE" = success || "$MODE" = success-off ]]; then test "$ACTUAL" = 9.0.2; else test "$ACTUAL" = 9.0.1; fi
codesign --verify --deep --strict "$OLD_APP"
cat "$ROOT/events.txt"
printf 'Evidence: %s\n' "$ROOT"
