import XCTest
@testable import iMicLink

final class MacSelectionTests: XCTestCase {
    private let b = MacCandidate(id: "B", paired: true, lastConnected: 10)
    private let c = MacCandidate(id: "C", paired: true, lastConnected: 20)
    private let d = MacCandidate(id: "D", paired: false)

    private func choose(_ candidates: [MacCandidate], preferred: String? = "A", expired: Bool = true,
                        anyPaired: Bool = true, excluded: Set<String> = [], manual: Bool = false,
                        preferredPaired: Bool = true) -> String? {
        MacSelection.choose(discovered: candidates, preferredID: preferred, graceExpired: expired,
            hasAnyPairedMac: anyPaired, excluded: excluded, manualSelection: manual,
            preferredIsPaired: preferredPaired)
    }

    func testPreferredPairedMacWinsBeforeGraceExpires() {
        XCTAssertEqual(choose([b, c], preferred: "B", expired: false), "B")
        XCTAssertEqual(choose([c, b], preferred: "B"), "B")
    }
    func testOfflinePreferredWaitsForGrace() {
        XCTAssertNil(choose([b, c], expired: false))
        XCTAssertEqual(MacSelection.preferredGrace, 1.5)
    }
    func testExpiredGraceUsesMostRecentlyAuthenticatedMac() {
        XCTAssertEqual(choose([b, c]), "C")
        XCTAssertEqual(choose([c, b]), "C")
    }
    func testAnyOfflinePairingPreventsAutomaticPairingOfStranger() {
        XCTAssertNil(choose([d]))
        XCTAssertNil(choose([d], preferred: nil))
    }
    func testFirstInstallConnectsOnlySingleDiscovery() {
        XCTAssertEqual(choose([d], preferred: nil, anyPaired: false), "D")
        XCTAssertNil(choose([d, MacCandidate(id: "E", paired: false)], preferred: nil, anyPaired: false))
        XCTAssertNil(choose([], preferred: nil, anyPaired: false))
    }
    func testNoPreferredDoesNotWait() {
        XCTAssertEqual(choose([b], preferred: nil, expired: false), "B")
    }
    func testFailedTargetsAreSkippedWithinRound() {
        XCTAssertEqual(choose([b, c], excluded: ["C"]), "B")
        XCTAssertNil(choose([b, c], excluded: ["B", "C"]))
        XCTAssertEqual(choose([b, c], preferred: "C", expired: false, excluded: ["C"]), "B")
        XCTAssertNil(choose([d], preferred: nil, anyPaired: false, excluded: ["D"]))
    }
    func testManualSelectionNeverFallsBack() {
        XCTAssertNil(choose([b, c], manual: true))
        XCTAssertEqual(choose([b, c], preferred: "B", manual: true), "B")
        XCTAssertEqual(choose([b, d], preferred: "D", manual: true), "D", "Explicit user selection can request pairing")
    }
    func testUnpairedPreferredDoesNotDelayPairedFallback() {
        XCTAssertEqual(choose([b, d], preferred: "D", expired: false), "B")
        XCTAssertEqual(choose([b], expired: false, preferredPaired: false), "B")
    }
    func testMissingOrEqualTimestampsHaveStableOrder() {
        let a = MacCandidate(id: "A", paired: true)
        let z = MacCandidate(id: "Z", paired: true)
        XCTAssertEqual(choose([z, a], preferred: nil), "A")
        XCTAssertEqual(choose([a, z], preferred: nil), "A")
        XCTAssertEqual(choose([c, MacCandidate(id: "B", paired: true, lastConnected: 20)], preferred: nil), "B")
    }
    func testBLEAllowlistContainsOnlyPairedMacsAndUsesSamePriority() {
        XCTAssertEqual(MacSelection.orderedPaired([c, d, b], preferredID: "B"), ["B", "C"])
        XCTAssertEqual(MacSelection.orderedPaired([b, c, d], preferredID: "offline"), ["C", "B"])
        XCTAssertEqual(MacSelection.orderedPaired([d], preferredID: "D"), [])
    }
}
