import Foundation
import Sparkle

enum PersonalUpdateConfiguration {
    static func isConfigured(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> Bool {
        if let identifier = infoDictionary?["CFBundleIdentifier"] as? String,
           identifier.hasSuffix(".dev") {
            return false // The personal appcast distributes the Release app.
        }
        guard let feed = infoDictionary?["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              host.lowercased() != "typewhisper.github.io",
              let key = infoDictionary?["SUPublicEDKey"] as? String,
              key != "OdAMiN136Ckglxnq4FeLagPjcrZiASYGaeUWBkK6tuc=",
              let data = Data(base64Encoded: key), data.count == 32 else {
            return false
        }
        return true
    }
}

@MainActor
struct UpdateChecker {
    let canCheckForUpdates: () -> Bool
    let checkForUpdates: () -> Void
    let resetUpdateCycleAfterSettingsChange: () -> Void

    static func sparkle(_ updater: SPUUpdater) -> UpdateChecker {
        let configured = PersonalUpdateConfiguration.isConfigured()
        return UpdateChecker(
            canCheckForUpdates: { configured && updater.canCheckForUpdates },
            checkForUpdates: {
                guard configured else { return }
                updater.checkForUpdates()
            },
            resetUpdateCycleAfterSettingsChange: {
                guard configured else { return }
                updater.resetUpdateCycleAfterShortDelay()
            }
        )
    }

    static var shared: UpdateChecker?
}
