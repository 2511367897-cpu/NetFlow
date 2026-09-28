import Foundation
import UIKit
import UserNotifications
import ActivityKit

@MainActor
final class SystemCapabilitiesService: ObservableObject {
    @Published private(set) var snapshot = SystemCapabilitySnapshot()

    func refresh(context: NetworkContextService) async {
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        let backgroundState = UIApplication.shared.backgroundRefreshStatus
        let notifications: CapabilityState = {
            switch notificationSettings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .available
            case .denied: return .unavailable
            case .notDetermined: return .limited
            @unknown default: return .unknown
            }
        }()

        let background: CapabilityState = {
            switch backgroundState {
            case .available:
                // Ordinary iOS apps cannot continuously sample in the background.
                // WidgetKit/ActivityKit have their own scheduling rules.
                return .limited
            case .denied, .restricted:
                return .unavailable
            @unknown default:
                return .unknown
            }
        }()

        // Connection-state detection is supported even when Wi-Fi/VPN is currently inactive.
        let wifiName: CapabilityState = .available
        let publicIP: CapabilityState = context.connection.publicIP == nil ? .limited : .available
        let vpn: CapabilityState = .available

        let liveActivities: CapabilityState = {
            guard Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool == true else {
                return .unavailable
            }

            if #available(iOS 16.2, *) {
                return ActivityAuthorizationInfo().areActivitiesEnabled ? .available : .limited
            }

            return .unavailable
        }()

        // Widget support requires an embedded extension at signing time.
        // This build reports the actual packaged capability instead of assuming it from installer names.
        let hasWidgetExtension = Bundle.main.builtInPlugInsURL.flatMap {
            try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }?.contains(where: { $0.pathExtension == "appex" && $0.lastPathComponent.localizedCaseInsensitiveContains("widget") }) == true

        let widgetState: CapabilityState = {
            guard hasWidgetExtension else { return .unavailable }
            return NetFlowWidgetBridge.isSharedContainerAvailable ? .available : .limited
        }()

        var items = [
            CapabilityItem(id: "usage", titleKey: "cap_usage", detailKey: "cap_usage_detail", systemImage: "chart.xyaxis.line", state: .available),
            CapabilityItem(id: "reports", titleKey: "cap_reports", detailKey: "cap_reports_detail", systemImage: "doc.richtext", state: .available),
            CapabilityItem(id: "notifications", titleKey: "cap_notifications", detailKey: "cap_notifications_detail", systemImage: "bell.badge", state: notifications),
            CapabilityItem(id: "background", titleKey: "cap_background", detailKey: "cap_background_detail", systemImage: "clock.arrow.circlepath", state: background),
            CapabilityItem(id: "ssid", titleKey: "cap_ssid", detailKey: "cap_ssid_detail", systemImage: "wifi", state: wifiName),
            CapabilityItem(id: "public_ip", titleKey: "cap_public_ip", detailKey: "cap_public_ip_detail", systemImage: "network", state: publicIP),
            CapabilityItem(id: "vpn", titleKey: "cap_vpn", detailKey: "cap_vpn_detail", systemImage: "lock.shield", state: vpn),
            CapabilityItem(id: "widgets", titleKey: "cap_widgets", detailKey: "cap_widgets_detail", systemImage: "square.grid.2x2", state: widgetState),
            CapabilityItem(id: "live_activities", titleKey: "cap_live_activities", detailKey: "cap_live_activities_detail", systemImage: "waveform.path.ecg.rectangle", state: liveActivities)
        ]

        // A capability-oriented label is more reliable than guessing LiveContainer/TrollStore from private paths.
        let enhancedCount = items.filter { $0.state == .available }.count
        let environmentTitle: String
        let environmentDetail: String
        if widgetState == .available && liveActivities == .available && notifications == .available {
            environmentTitle = "environment_full"
            environmentDetail = "environment_full_detail"
        } else if enhancedCount >= 6 {
            environmentTitle = "environment_standard"
            environmentDetail = "environment_standard_detail"
        } else {
            environmentTitle = "environment_limited"
            environmentDetail = "environment_limited_detail"
        }

        items.sort { $0.id < $1.id }
        snapshot = SystemCapabilitySnapshot(
            environmentTitleKey: environmentTitle,
            environmentDetailKey: environmentDetail,
            items: items,
            lastChecked: Date()
        )
    }
}
