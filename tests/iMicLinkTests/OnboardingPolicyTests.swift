import XCTest
@testable import iMicLink

final class OnboardingPolicyTests: XCTestCase {
    func testNewInstall() {
        XCTAssertEqual(OnboardingPolicy.decide(completedVersion: 0, savedStep: nil, hasPairedMac: false), .show(.welcome))
    }
    func testCompletedAndFutureVersions() {
        for version in [1, 2] {
            XCTAssertEqual(OnboardingPolicy.decide(completedVersion: version, savedStep: .pair, hasPairedMac: true), .skip)
        }
    }
    func testEveryStepResumesEvenAfterPairing() {
        for step in OnboardingStep.allCases {
            for paired in [false, true] {
                XCTAssertEqual(OnboardingPolicy.decide(completedVersion: 0, savedStep: step, hasPairedMac: paired), .show(step))
            }
        }
    }
    func testExistingPairedUser() {
        XCTAssertEqual(OnboardingPolicy.decide(completedVersion: 0, savedStep: nil, hasPairedMac: true), .skipAndMarkComplete)
    }
    func testOlderVersion() {
        XCTAssertEqual(OnboardingPolicy.decide(completedVersion: -1, savedStep: nil, hasPairedMac: false), .show(.welcome))
    }
}
