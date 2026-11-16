import XCTest
@testable import iMicLink

final class MacSelectionTests: XCTestCase {
    private let b = MacCandidate(id: "B", paired: true, lastConnected: 10)
    private let c = MacCandidate(id: "C", paired: true, lastConnected: 20)
    private let d = MacCandidate(id: "D", paired: false)
    private func choose(_ candidates: [MacCandidate], preferred: String? = "A", expired: Bool = true,
                        anyPaired: Bool = true, excluded: Set<String> = [], manual: Bool = false) -> String? {
        MacSelection.choose(discovered: candidates, preferredID: preferred, graceExpired: expired,
                            hasAnyPairedMac: anyPaired, excluded: excluded, manualSelection: manual)
    }
    func testPreferredWinsRegardlessOfDiscoveryOrderOrRecency() {
        XCTAssertEqual(choose([b, c], preferred: "B", expired: false), "B")
        XCTAssertEqual(choose([c, b], preferred: "B"), "B")
    }
    func testOfflinePreferredNeverFallsBackAfterGrace() {
        XCTAssertNil(choose([b, c], expired: false))
        XCTAssertNil(choose([c, b], expired: true))
    }
    func testFailedPreferredWaitsForItsRetryInsteadOfTryingOthers() {
        XCTAssertNil(choose([b,c], preferred:"C", excluded:["C"]))
        XCTAssertEqual(choose([b,c], preferred:"C"), "C")
    }
    func testRevokedPreferredCannotAutoPairOrRedirect() {
        XCTAssertNil(choose([d,b], preferred:"D"))
        XCTAssertNil(choose([b], preferred:"D"))
        XCTAssertEqual(choose([d,b], preferred:"D", manual:true), "D")
    }
    func testAmbiguousPairingHistoryRequiresExplicitChoice() {
        XCTAssertNil(choose([b,c], preferred:nil))
        XCTAssertNil(choose([b], preferred:nil))
    }
    func testOfflinePairingPreventsAutomaticPairingOfStranger() {
        XCTAssertNil(choose([d]))
        XCTAssertNil(choose([d], preferred:nil))
    }
    func testFirstInstallOnlyStartsSingleDiscoveryPairing() {
        XCTAssertEqual(choose([d], preferred:nil, anyPaired:false), "D")
        XCTAssertNil(choose([d,MacCandidate(id:"E",paired:false)], preferred:nil, anyPaired:false))
        XCTAssertNil(choose([d], preferred:nil, anyPaired:false, excluded:["D"]))
        XCTAssertNil(choose([], preferred:nil, anyPaired:false))
    }
    func testManualOfflineChoiceNeverFallsBack() {
        XCTAssertNil(choose([b,c], manual:true))
        XCTAssertEqual(choose([b,c], preferred:"B", manual:true), "B")
        XCTAssertNil(choose([b], preferred:nil, manual:true))
    }
    func testNewSuccessfulIdentityWinsOverManualAndOldTimestamps() {
        XCTAssertEqual(MacSelection.restoredTarget([b,c], successfulID:"B", legacyPreferredID:"C"), "B")
    }
    func testMigrateAuthenticatedHistoryInsteadOfUnsuccessfulClick() {
        XCTAssertEqual(MacSelection.restoredTarget([b,c,d], successfulID:nil, legacyPreferredID:"D"), "C")
    }
    func testRestoreOfflineOrRevokedLastDeviceWithoutChoosingAnother() {
        XCTAssertEqual(MacSelection.restoredTarget([b], successfulID:"offline", legacyPreferredID:nil), "offline")
        XCTAssertEqual(MacSelection.restoredTarget([d,b], successfulID:"D", legacyPreferredID:"B"), "D")
    }
    func testLegacyWithoutTimestampsKeepsTargetOrOnlyPairing() {
        XCTAssertEqual(MacSelection.restoredTarget([MacCandidate(id:"B",paired:true),MacCandidate(id:"C",paired:true)], successfulID:nil, legacyPreferredID:"B"), "B")
        XCTAssertEqual(MacSelection.restoredTarget([b,d], successfulID:nil, legacyPreferredID:nil), "B")
        let noDates = [MacCandidate(id:"B",paired:true),MacCandidate(id:"C",paired:true)]
        XCTAssertNil(MacSelection.restoredTarget(noDates, successfulID:nil, legacyPreferredID:nil))
    }
    func testEqualTimestampsAndNonfiniteHistoryAreDeterministic() {
        let a = MacCandidate(id:"A",paired:true,lastConnected:20)
        XCTAssertEqual(MacSelection.restoredTarget([c,a], successfulID:nil, legacyPreferredID:nil), "A")
        XCTAssertEqual(MacSelection.restoredTarget([a,c], successfulID:nil, legacyPreferredID:"C"), "C")
        XCTAssertEqual(MacSelection.restoredTarget([b,MacCandidate(id:"bad",paired:true,lastConnected:.nan)], successfulID:nil, legacyPreferredID:nil), "B")
    }
    func testBluetoothOnlyAcceptsTheSameSelectedPairedIdentity() {
        XCTAssertEqual(MacSelection.bluetoothTargets([b,c,d], preferredID:"B", excluded:[]), ["B"])
        XCTAssertEqual(MacSelection.bluetoothTargets([b,c], preferredID:"offline", excluded:[]), [])
        XCTAssertEqual(MacSelection.bluetoothTargets([b,c], preferredID:"B", excluded:["B"]), [])
        XCTAssertEqual(MacSelection.bluetoothTargets([b,c,d], preferredID:"D", excluded:[]), [])
        XCTAssertEqual(MacSelection.bluetoothTargets([b,c], preferredID:nil, excluded:[]), [])
    }
}
