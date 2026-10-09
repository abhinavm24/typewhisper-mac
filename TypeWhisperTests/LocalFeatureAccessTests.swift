import Foundation
import XCTest
@testable import TypeWhisper

final class LocalFeatureAccessTests: XCTestCase {
    @MainActor
    func testUnlicensedServiceAllowsCorrectionLearning() {
        let suiteName = "LocalFeatureAccess-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let license = LicenseService(defaults: defaults)

        XCTAssertFalse(license.hasCommercialLicense)
        XCTAssertTrue(license.canUseCorrectionLearning)
    }

    func testCustomFolderSyncDoesNotUnlockAutomaticICloud() {
        XCTAssertTrue(LocalFeatureAccess.canUseCloudSync(
            mode: .cloudFolder,
            hasPremiumAccountAccess: false,
            isSmokeTest: false
        ))
        XCTAssertFalse(LocalFeatureAccess.canUseCloudSync(
            mode: .automaticICloud,
            hasPremiumAccountAccess: false,
            isSmokeTest: false
        ))
        XCTAssertEqual(
            LocalFeatureAccess.availableCloudSyncModes(
                automaticICloudAvailable: true,
                hasPremiumAccountAccess: false,
                isSmokeTest: false
            ),
            [.off, .cloudFolder]
        )
    }

    func testAutomaticICloudRequiresAvailabilityAndPremiumAccess() {
        XCTAssertTrue(LocalFeatureAccess.canUseCloudSync(
            mode: .automaticICloud,
            hasPremiumAccountAccess: true,
            isSmokeTest: false
        ))
        XCTAssertEqual(
            LocalFeatureAccess.availableCloudSyncModes(
                automaticICloudAvailable: true,
                hasPremiumAccountAccess: true,
                isSmokeTest: false
            ),
            PremiumSyncMode.allCases
        )
        XCTAssertEqual(
            LocalFeatureAccess.availableCloudSyncModes(
                automaticICloudAvailable: false,
                hasPremiumAccountAccess: true,
                isSmokeTest: false
            ),
            [.off, .cloudFolder]
        )
    }
}
