#!/bin/bash
set -euo pipefail
DEVICE_ID="$1"
SIGNING_MODE="${2:-standard}"
PROBE_SIM_ARCH="$(uname -m)"
SIGNING_ARGS=()
if [ "$SIGNING_MODE" != standard ]; then
  # Reproduce the uploaded enterprise package's SIGNED entitlement shape using
  # a synthetic identity; never upload the user's provisioning profile to CI.
  python3 - "$SIGNING_MODE" <<'PY'
import plistlib,sys
from pathlib import Path
mode=sys.argv[1]
assert mode in ('resigned-wildcard','resigned-concrete'),mode
group='FLOWLEDGER.*' if mode=='resigned-wildcard' else 'FLOWLEDGER.app.resigned.identity'
ent={'application-identifier':'FLOWLEDGER.app.resigned.identity',
     'com.apple.developer.team-identifier':'FLOWLEDGER',
     'keychain-access-groups':[group,'com.apple.token']}
Path('ci-resigned.entitlements').write_bytes(plistlib.dumps(ent))
PY
  SIGNING_ARGS+=("CODE_SIGN_ENTITLEMENTS=$PWD/ci-resigned.entitlements")
fi
launch_with_retry() {
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if xcrun simctl launch --terminate-running-process "$DEVICE_ID" "$@"; then return 0; fi
    sleep 2
  done
  return 1
}
# Use Xcode's simulator entitlement injection and signing for every binary,
# including debug dylibs; changing only the outer app signature is insufficient.
xcodebuild -project NetFlow.xcodeproj -scheme NetFlow -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath signed-sim-build CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=FLOWLEDGER \
  AppIdentifierPrefix=FLOWLEDGER. ENABLE_DEBUG_DYLIB=NO ONLY_ACTIVE_ARCH=YES ARCHS="$PROBE_SIM_ARCH" "${SIGNING_ARGS[@]}" build
xcodegen generate --spec Tools/KeychainProbe/project.yml --project Tools/KeychainProbe
xcodebuild -project Tools/KeychainProbe/FlowLedgerProbe.xcodeproj \
  -scheme FlowLedgerKeychainProbe -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath probe-build \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM=FLOWLEDGER CODE_SIGN_STYLE=Manual AppIdentifierPrefix=FLOWLEDGER. ENABLE_DEBUG_DYLIB=NO ONLY_ACTIVE_ARCH=YES ARCHS="$PROBE_SIM_ARCH" "${SIGNING_ARGS[@]}" build
python3 - "$SIGNING_MODE" <<'PY'
import json,plistlib,subprocess,sys
from pathlib import Path
mode=sys.argv[1]
paths={'app':'signed-sim-build/Build/Products/Debug-iphonesimulator/NetFlow.app',
       'widget':'signed-sim-build/Build/Products/Debug-iphonesimulator/NetFlow.app/PlugIns/NetFlowWidget.appex',
       'reader':'probe-build/Build/Products/Debug-iphonesimulator/FlowLedgerKeychainProbe.app'}
evidence={}
for name,path in paths.items():
    raw=subprocess.check_output(['codesign','-d','--entitlements',':-',path],stderr=subprocess.DEVNULL)
    ent=plistlib.loads(raw)
    evidence[name]={k:ent.get(k) for k in ('application-identifier','keychain-access-groups')}
    if mode!='standard':
        group='FLOWLEDGER.*' if mode=='resigned-wildcard' else 'FLOWLEDGER.app.resigned.identity'
        assert ent.get('keychain-access-groups')==[group,'com.apple.token'],(name,ent)
        assert ent.get('application-identifier')=='FLOWLEDGER.app.resigned.identity',(name,ent)
Path('signing-entitlements.json').write_text(json.dumps(evidence,indent=2))
print('Verified actual code signatures:',evidence)
PY
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl install "$DEVICE_ID" signed-sim-build/Build/Products/Debug-iphonesimulator/NetFlow.app
launch_with_retry com.jack.flowledger --ui-smoke
sleep 3
xcrun simctl io "$DEVICE_ID" screenshot FlowLedger-first-launch.png
xcrun simctl install "$DEVICE_ID" probe-build/Build/Products/Debug-iphonesimulator/FlowLedgerKeychainProbe.app
PROBE_APP="$(xcrun simctl get_app_container "$DEVICE_ID" com.jack.flowledger.keychainprobe app)"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PROBE_APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$PROBE_APP/Info.plist"
launch_with_retry com.jack.flowledger.keychainprobe
PROBE_DATA="$(xcrun simctl get_app_container "$DEVICE_ID" com.jack.flowledger.keychainprobe data)"
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if [ -f "$PROBE_DATA/Documents/probe-result.json" ]; then break; fi
  sleep 2
done
cp "$PROBE_DATA/Documents/probe-result.json" keychain-probe-result.json
python3 - "$SIGNING_MODE" <<'PY'
import json,time
import sys
from pathlib import Path
result=json.loads(Path('keychain-probe-result.json').read_text())
assert result.get('success') is True,result
assert result.get('schema')==1,result
assert abs(time.time()-result['sampledAt'])<120,result
expected={'standard':'FLOWLEDGER.com.jack.flowledger',
          'resigned-wildcard':'FLOWLEDGER.*',
          'resigned-concrete':'FLOWLEDGER.app.resigned.identity'}[sys.argv[1]]
assert result.get('accessGroup')==expected,result
print('Cross-process app -> widget-identity keychain read passed:',result)
PY
