# Shared sim-harness for the T4 full-stack screenshot script(s). SOURCED, not executed.
#
# Extracted (D10) from the byte-identical block that t4-takeover-shot.sh and its former
# --spawn twin each carried. The caller must set these globals before calling in:
#   ROOT       repo root (cwd)
#   BUNDLE     app bundle id
#   BUILD_LOG  path for the xcodebuild log
#   D          throwaway sshd scratch dir
#   PORT       loopback port for the throwaway sshd
# Provides (each sets globals the next step / caller reads):
#   t4_build_install  → APP, UDID   (build ad-hoc-signed, boot a sim, install)
#   t4_export_pubkey  → PUBKEY_FILE (pass-1 launch so the app exports its device key)
#   t4_start_sshd                    (throwaway non-root sshd on :$PORT trusting that key)

t4_build_install() {
  echo "=== build (Debug, ad-hoc signed — Keychain entitlement) ==="
  xcodegen generate --spec App-iOS/project.yml --project App-iOS >/dev/null
  xcodebuild -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- \
    build > "$BUILD_LOG" 2>&1 || { echo "BUILD FAILED"; tail -20 "$BUILD_LOG"; exit 1; }
  APP="$(xcodebuild -project App-iOS/OrchestraiOS.xcodeproj -scheme OrchestraiOS -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR / {d=$2} / FULL_PRODUCT_NAME / {n=$2} END {print d "/" n}')"
  [ -d "$APP" ] || { echo "no .app"; exit 1; }

  UDID="$(xcrun simctl list devices available | grep -m1 '    iPhone ' | grep -oE '[0-9A-Fa-f-]{36}' | head -1)"
  echo "UDID=$UDID"
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl install "$UDID" "$APP"
}

t4_export_pubkey() {
  echo "=== pass 1: generate + export device pubkey ==="
  xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  sleep 6
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null)"
  PUBKEY_FILE="$CONTAINER/Documents/orchestra-ios-pubkey.txt"
  for i in $(seq 1 10); do [ -s "$PUBKEY_FILE" ] && break; sleep 1; done
  [ -s "$PUBKEY_FILE" ] || { echo "no device pubkey exported"; exit 1; }
}

t4_start_sshd() {
  echo "=== throwaway sshd :$PORT ==="
  rm -rf "$D"; mkdir -p "$D"; D="$(cd "$D" && pwd)"
  ssh-keygen -q -t ed25519 -f "$D/hostkey" -N ""
  cat "$PUBKEY_FILE" > "$D/authorized_keys"; chmod 600 "$D/authorized_keys" "$D/hostkey"
  cat > "$D/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $D/hostkey
PidFile $D/sshd.pid
AuthorizedKeysFile $D/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PubkeyAuthentication yes
AcceptEnv LANG LC_*
EOF
  /usr/sbin/sshd -f "$D/sshd_config" -E "$D/sshd.log"
  sleep 1
  pgrep -fl "sshd -f $D" >/dev/null || { echo "sshd failed"; tail "$D/sshd.log"; exit 1; }
}
