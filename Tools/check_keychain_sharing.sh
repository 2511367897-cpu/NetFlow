#!/bin/bash
set -euo pipefail
DEVICE_ID="$1"
SMOKE_DIR="$(mktemp -d)"
trap 'rm -rf "$SMOKE_DIR"' EXIT
xcodegen generate --spec Tools/KeychainProbe/project.yml --project Tools/KeychainProbe
xcodebuild -project Tools/KeychainProbe/FlowLedgerProbe.xcodeproj \
  -scheme FlowLedgerKeychainProbe -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath probe-build \
  CODE_SIGNING_ALLOWED=NO build
cp -R test-build/Build/Products/Debug-iphonesimulator/NetFlow.app "$SMOKE_DIR/NetFlow.app"
# Reserve the extension's bundle identity for the separate CI reader host.
# The release IPA is built separately, with the actual WidgetKit extension.
rm -rf "$SMOKE_DIR/NetFlow.app/PlugIns"
python3 - "$SMOKE_DIR" <<'PY'
import plistlib,sys
from pathlib import Path
root=Path(sys.argv[1])
prefix='FLOWLEDGER.'
for role,bundle in [('app','com.jack.flowledger'),('widget','com.jack.flowledger.widget')]:
    groups=[prefix+bundle]
    if role=='widget':groups.append(prefix+'com.jack.flowledger')
    entitlements={'application-identifier':prefix+bundle,
                  'com.apple.developer.team-identifier':'FLOWLEDGER',
                  'keychain-access-groups':groups,'get-task-allow':True}
    (root/(role+'.plist')).write_bytes(plistlib.dumps(entitlements))
PY
codesign --force --sign - --entitlements "$SMOKE_DIR/app.plist" "$SMOKE_DIR/NetFlow.app"
codesign --force --sign - --entitlements "$SMOKE_DIR/widget.plist" probe-build/Build/Products/Debug-iphonesimulator/FlowLedgerKeychainProbe.app
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl install "$DEVICE_ID" "$SMOKE_DIR/NetFlow.app"
xcrun simctl launch --terminate-running-process "$DEVICE_ID" com.jack.flowledger --ui-smoke
sleep 3
xcrun simctl io "$DEVICE_ID" screenshot FlowLedger-first-launch.png
xcrun simctl install "$DEVICE_ID" probe-build/Build/Products/Debug-iphonesimulator/FlowLedgerKeychainProbe.app
xcrun simctl launch --terminate-running-process "$DEVICE_ID" com.jack.flowledger.widget
sleep 3
PROBE_DATA="$(xcrun simctl get_app_container "$DEVICE_ID" com.jack.flowledger.widget data)"
cp "$PROBE_DATA/Documents/probe-result.json" keychain-probe-result.json
python3 - <<'PY'
import json,time
from pathlib import Path
result=json.loads(Path('keychain-probe-result.json').read_text())
assert result.get('success') is True,result
assert result.get('schema')==1,result
assert abs(time.time()-result['sampledAt'])<120,result
print('Cross-process app -> widget-identity keychain read passed:',result)
PY
