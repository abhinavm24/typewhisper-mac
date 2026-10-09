enum LocalFeatureAccess {
    #if APPSTORE
    // Personal direct-distribution overrides must not alter StoreKit access.
    static let correctionLearning = false
    static let automaticTranscriptionFallback = false
    static let customFolderSync = false
    #else
    static let correctionLearning = true
    static let automaticTranscriptionFallback = true
    static let customFolderSync = true
    #endif

    static func canUseCloudSync(
        mode: PremiumSyncMode,
        hasPremiumAccountAccess: Bool,
        isSmokeTest: Bool
    ) -> Bool {
        switch mode {
        case .off, .cloudFolder:
            return customFolderSync || hasPremiumAccountAccess || isSmokeTest
        case .automaticICloud:
            return hasPremiumAccountAccess || isSmokeTest
        }
    }

    static func availableCloudSyncModes(
        automaticICloudAvailable: Bool,
        hasPremiumAccountAccess: Bool,
        isSmokeTest: Bool
    ) -> [PremiumSyncMode] {
        guard automaticICloudAvailable,
              hasPremiumAccountAccess || isSmokeTest else {
            return [.off, .cloudFolder]
        }
        return PremiumSyncMode.allCases
    }
}
