import SwiftUI

// CI-only client with a distinct bundle ID and the widget's shared access group.
// It exercises the production reader and widget root resolution in another process.
// It is never embedded in the IPA.
@main
struct KeychainProbeApp: App {
    var body: some Scene {
        WindowGroup {
            Text("FlowLedger keychain integration probe")
                .task {
                    var result: [String: Any] = ["success": false]
                    do {
                        let store = SharedLedgerStore(applicationBundleIdentifier: "com.jack.flowledger.widget")
                        if let snapshot = try store.read() {
                            result = ["success": true, "schema": snapshot.schema,
                                      "accessGroup": try store.sharedGroup(),
                                      "sampledAt": snapshot.sampledAt.timeIntervalSince1970,
                                      "todayCellular": snapshot.todayCellular,
                                      "monthCellular": snapshot.monthCellular,
                                      "planUsed": snapshot.planUsed]
                        } else { result["error"] = "App snapshot not found" }
                    } catch { result["error"] = error.localizedDescription }
                    let document = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("probe-result.json")
                    do {
                        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                        try data.write(to: document, options: .atomic)
                    } catch { print("Probe report write failed: \(error)") }
                }
        }
    }
}
