import Foundation

// Migration cache for snapshots saved before atomic persistence was introduced.
enum NetworkSnapshotCache {
    private static let key = "NetFlow.lastNetworkSnapshot"

    static func load() -> NetworkSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder.netFlow.decode(NetworkSnapshot.self, from: data)
    }

    static func save(_ snapshot: NetworkSnapshot) {
        guard snapshot.timestamp != .distantPast,
              let data = try? JSONEncoder.pretty.encode(snapshot) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
