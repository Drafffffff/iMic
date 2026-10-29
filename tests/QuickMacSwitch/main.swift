import Foundation

// Transport/session/haptic boundaries only. The production coordinator, return
// timer and menu model are compiled unchanged, alongside the real MacSelection.
struct RememberedMac { let id: String; let name: String }
struct DiscoveredMac { let id: String; let name: String }
final class LinkClient {
    enum Phase { case idle, searching, connecting(String), needsCode(String), ready(String), failed(String)
        var isReady: Bool { if case .ready = self { return true }; return false }
    }
    enum Transport { case network, bluetooth }
    var phase: Phase = .ready("A")
    var selectedMacID: String? = "a"
    var pairedMacIDs: Set<String> = ["a", "b", "offline"]
    var macs = [DiscoveredMac(id: "a", name: "A"), DiscoveredMac(id: "b", name: "B")]
    var rememberedMacs = [RememberedMac(id: "a", name: "A"), RememberedMac(id: "b", name: "B"), RememberedMac(id: "offline", name: "Offline")]
    var macConnectionDates: [String: Double] = ["a": 1, "b": 2, "offline": 100]
    var transport: Transport? = .network
    var selected: [String] = []
    func connect(to mac: DiscoveredMac) { selected.append("nearby:\(mac.id)") }
    func selectRememberedMac(_ mac: RememberedMac) { selected.append("remembered:\(mac.id)") }
}
@MainActor final class SessionModel {
    enum Phase { case idle, listening, transcribing, result }
    var phase: Phase = .idle
    var isUploading = false
    var cancellations = 0
    func cancelForDeviceSwitch() { cancellations += 1; phase = .idle }
}
@MainActor final class Haptics {
    enum Event { case selection }
    static let shared = Haptics()
    var count = 0
    func play(_ event: Event) { count += 1 }
}
enum Failure: Error { case failed(String) }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure.failed(message) }
}
Task { @MainActor in
    do {
        let target = RememberedMac(id: "b", name: "B")
        for phase in [SessionModel.Phase.listening, .transcribing, .idle] {
            let link = LinkClient(), session = SessionModel(), coordinator = MacSwitchCoordinator()
            session.phase = phase; session.isUploading = phase == .idle
            coordinator.request(target, link: link, session: session)
            try check(coordinator.showingConfirmation && link.selected.isEmpty && session.cancellations == 0,
                      "Active voice must not switch before confirmation")
            coordinator.cancel(); coordinator.confirm()
            try check(link.selected.isEmpty && session.cancellations == 0, "Cancel cannot replay a pending action")
            coordinator.request(target, link: link, session: session); coordinator.confirm(); coordinator.confirm()
            try check(link.selected == ["nearby:b"] && session.cancellations == 1, "Confirm must cancel and switch once")
        }
        print("PASS recording, waiting result and uploading require confirmation; cancel preserves session; confirm executes once")
        let link = LinkClient(), session = SessionModel(), coordinator = MacSwitchCoordinator()
        session.phase = .listening
        coordinator.request(RememberedMac(id: "a", name: "A"), link: link, session: session)
        try check(!coordinator.showingConfirmation && session.cancellations == 0 && link.selected.isEmpty,
                  "Current connected target is a no-op even while recording")
        session.phase = .idle
        coordinator.request(RememberedMac(id: "offline", name: "Offline"), link: link, session: session)
        try check(link.selected == ["remembered:offline"], "Offline selection uses existing remembered-Mac entry point")
        print("PASS current target no-op and offline handoff")

        link.macs.append(DiscoveredMac(id: "new", name: "Unpaired"))
        try check(QuickMacTarget.paired(in: link).map(\.id) == ["a", "b", "offline"],
                  "Connected first, online before a more recently used offline Mac; unpaired excluded")
        link.macs.removeAll { $0.id == "a" }
        try check(QuickMacTarget.paired(in: link).first?.status == "局域网", "Live connection survives Bonjour disappearing")
        link.transport = .bluetooth
        try check(QuickMacTarget.paired(in: link).first?.status == "蓝牙", "BLE connection has correct status")
        link.phase = .searching; link.selectedMacID = "offline"
        let targets = QuickMacTarget.paired(in: link)
        try check(targets.map(\.id) == ["b", "offline", "a"] && targets[1].current,
                  "Disconnected current target is checked but does not outrank online devices")
        print("PASS menu order, availability, checkmark target and unpaired filtering")

        let returning = MacSwitchReturn()
        link.selectedMacID = "b"; link.phase = .connecting("B")
        var returned = 0
        returning.begin(id: "b", paired: true, link: link) { returned += 1 }
        try await Task.sleep(for: .milliseconds(200))
        try check(returned == 0, "Connection must remain visible for 350ms")
        try await Task.sleep(for: .milliseconds(190))
        try check(returned == 1, "Stable connecting target returns automatically")
        returning.begin(id: "b", paired: true, link: link) { returned += 1 }
        returning.cancel() // User scrolls, selects another row or leaves the page.
        try await Task.sleep(for: .milliseconds(390))
        try check(returned == 1, "User interaction cancels automatic return")
        returning.begin(id: "b", paired: true, link: link) { returned += 1 }
        link.phase = .failed("offline"); returning.update(link: link) { returned += 1 }
        try await Task.sleep(for: .milliseconds(390))
        try check(returned == 1, "A failed connection cancels its connecting timer")
        link.phase = .connecting("B")
        returning.begin(id: "b", paired: false, link: link) { returned += 1 }
        try await Task.sleep(for: .milliseconds(390))
        try check(returned == 1, "Unpaired target must stay for pairing")
        link.phase = .ready("B"); returning.update(link: link) { returned += 1 }
        try check(returned == 2, "Pairing success returns immediately")
        link.selectedMacID = "a"
        returning.begin(id: "b", paired: true, link: link) { returned += 1 }
        try check(returned == 2, "Old target ready cannot dismiss a different selection")
        returning.cancel()
        print("PASS 350ms auto-return, user cancellation, failure, pairing success and target isolation")
        exit(0)
    } catch { fputs("FAIL \(error)\n", stderr); exit(1) }
}
dispatchMain()
