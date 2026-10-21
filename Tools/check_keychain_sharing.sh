#!/bin/bash
set -euo pipefail
DEVICE_ID="$1"
# Use Xcode's simulator entitlement injection and signing for every binary,
# including debug dylibs; changing only the outer app signature is insufficient.
xcodebuild -project NetFlow.xcodeproj -scheme NetFlow -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath signed-sim-build CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=FLOWLEDGER \
  AppIdentifierPrefix=FLOWLEDGER. ENABLE_DEBUG_DYLIB=NO build
xcodegen generate --spec Tools/KeychainProbe/project.yml --project Tools/KeychainProbe
xcodebuild -project Tools/KeychainProbe/FlowLedgerProbe.xcodeproj \
  -scheme FlowLedgerKeychainProbe -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath probe-build \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM=FLOWLEDGER CODE_SIGN_STYLE=Manual AppIdentifierPrefix=FLOWLEDGER. ENABLE_DEBUG_DYLIB=NO build
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl install "$DEVICE_ID" signed-sim-build/Build/Products/Debug-iphonesimulator/NetFlow.app
xcrun simctl launch --terminate-running-process "$DEVICE_ID" com.jack.flowledger --ui-smoke
sleep 3
xcrun simctl io "$DEVICE_ID" screenshot FlowLedger-first-launch.png
xcrun simctl install "$DEVICE_ID" probe-build/Build/Products/Debug-iphonesimulator/FlowLedgerKeychainProbe.app
xcrun simctl launch --terminate-running-process "$DEVICE_ID" com.jack.flowledger.keychainprobe
sleep 3
PROBE_DATA="$(xcrun simctl get_app_container "$DEVICE_ID" com.jack.flowledger.keychainprobe data)"
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
