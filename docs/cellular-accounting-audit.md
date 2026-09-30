# Cellular accounting audit — 2026-09-30

Audited GitHub main `a4a73a24afacc662aea46a9c7df35ad34af5a30e`, rather than the older local widget branch. That HEAD's Actions run 36659138091 passed. App sources are in `NetFlow`, the independent extension is in `NetFlowWidget`, and both use `Shared/InterfaceCounters.swift`. `project.yml` generates the app, widget and XCTest targets.

## Confirmed code-level loss and fix

The shared reader first requests 64-bit routing counters (`NET_RT_IFLIST2` / `if_data64`). When that fails it falls back to `getifaddrs` / `if_data`, whose byte fields are **32-bit**. Casting these fields to `UInt64` does not restore their high bits. Earlier code used those narrow fields, and an aggregate regression could discard unrelated cellular deltas; main already contains fixes for these problems.

At the audited HEAD, both accounting consumers still discarded a sample whenever the width changed and **committed the changed-width baseline**. A temporary fallback therefore discarded the wide-to-narrow interval, then discarded the narrow-to-wide interval too. Repeated failures could erase long background gaps despite functioning 64-bit readings before and after them.

4.2.16 keeps the last wide baseline, timestamp and remembered interfaces when a narrow reading arrives within the same boot. A recovered wide reading accounts for the entire gap exactly once. The app and widget share the acceptance rule. A detected reboot allows a new baseline because the old boot's counters cannot be recovered. Initial 32-bit-only installations and the existing upgrade migration continue to work; their limitations are below.

Sampling also starts before network-context queries and notification permissions. These unrelated awaits previously delayed the first baseline and the resume sample. The background transition takes a final synchronous sample and persists records together with the baseline.

The checked-in Xcode project was stale: it omitted the shared reader even though Actions regenerated it correctly. The project is regenerated for this release.

## Source, scope and unavoidable gaps

- All exposed `pdp_ip*` interfaces are summed independently of current `NWPathMonitor` status. This reads device interface counters, rather than NetFlow's requests or a list of other apps. A Wi-Fi reset does not invalidate a cellular delta.
- `en0` is Wi-Fi. `utun`, loopback and other virtual interfaces are excluded. VPN packets using cellular must traverse the physical cellular interface; adding tunnel counters would count the same traffic twice. NetFlow cannot produce the Settings app's per-app attribution from these counters.
- There is no packet-tunnel extension or continuous background entitlement. Ordinary App tasks stop during suspension; WidgetKit refresh timing is controlled by iOS. A retained cumulative counter can still recover traffic while neither process is running. Increasing a foreground timer frequency cannot fix counters that reset or disappear between executions.
- Hotspot traffic is included only to the extent that iOS exposes it in these physical cellular counters. Modem/offloaded traffic and billing classifications require a physical-device comparison; they cannot be certified from simulator tests.
- If an interface is destroyed, resets, or the phone reboots between observations, bytes accumulated before that reset are unavailable. If only the 32-bit fallback is available, multiple wraps during suspension cannot be reconstructed. Once a wide baseline exists, a sustained narrow-only period now leaves it pending rather than silently replacing it; recovery requires a wide reading from that boot.
- On first install, manual reset, backup restore, or migration from an unknown/32-bit baseline, the code cannot identify the Settings reset boundary from lifetime counters. Settings' September 27 23:07 reset is not an API reset of NetFlow's counter source. It would be incorrect to import all pre-existing lifetime bytes as usage since that time.
- App and widget currently keep independent histories and start dates, with no App Group. They must be validated separately and their totals must not be added. Changing storage/signing architecture is outside this focused fix.

The reported Settings **7.10 GB** versus NetFlow **115 MB** establishes serious undercounting. The defects above are reproducible in code, but the exact contribution of each defect on that phone remains unverified without counters from the device. Existing calibration can align the plan total with an externally observed total; it does not reconstruct lost daily history or demonstrate that measurement is fixed.

## Validation

Regression tests exercise a 7,100,000,000-byte interval with repeated narrow fallback, JSON persistence, process restart, recovery and duplicate prevention, including temporarily missing interfaces and reboot handling. An AppStore test verifies that disk persistence retains the wide baseline and commits the recovered usage. Existing tests cover counter resets, wrap, multi-day aggregation and calibration. Actions runs simulator XCTest and an unsigned device build and packages the IPA.

On a physical iPhone, compare **new deltas after installing this build**, not the already-lost historical total:

1. Record the Settings cellular total and NetFlow total at the same time; establish a NetFlow baseline while cellular is connected.
2. Download a known large file in another app with Wi-Fi disabled, keep NetFlow suspended, then reopen it. Compare the change in both totals.
3. Repeat over a gap exceeding 4.29 GB, with VPN enabled over cellular, and with a hotspot client. Record these cases separately.
4. Repeat after an app termination and relaunch without a phone reboot. Stable counters should recover the full delta.
5. Test Wi-Fi/cellular switching and airplane mode separately; these may reset or recreate interfaces. A phone reboot is a distinct case with a known unrecoverable pre-reset interval.

Primary references: [Apple kernel counter conversion](https://github.com/apple/darwin-xnu/blob/main/bsd/net/if.c), [Apple background execution](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).
