import SwiftUI

// CI-only host with the widget's identity and access groups. It exercises the
// production reader in a separate process; it is never embedded in the IPA.
@main
struct KeychainProbeApp: App {
    var body: some Scene {
        WindowGroup {
            Text("FlowLedger keychain integration probe")
                .task {
                    var result: [String: Any] = ["success": false]
                    do {
                        if let snapshot = try SharedLedgerStore().read() {
                            result = ["success": true, "schema": snapshot.schema,
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
