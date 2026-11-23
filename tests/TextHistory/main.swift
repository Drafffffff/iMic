import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition { print("PASS \(message)") } else { failures += 1; print("FAIL \(message)") }
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxchord-history-\(UUID().uuidString)/nested")
defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

let store = TextHistoryStore(directory: directory)
check(store.entries().isEmpty, "missing file reads as empty history")
let polish = TextHistoryEntry.Polish(mode: "agent", tone: "normal", output: "chinese", fallback: false)
let first = TextHistoryEntry(date: Date(timeIntervalSince1970: 1_700_000_000), appName: "Notes", bundleID: "com.apple.Notes",
                             original: "嗯 那个 会议改到周四", final: "会议改到周四。", polish: polish, outcome: .typed)
let second = TextHistoryEntry(date: Date(timeIntervalSince1970: 1_700_000_100), appName: "Terminal", bundleID: nil,
                              original: "List Files", final: "ls -la", polish: nil, outcome: .kept)
let third = TextHistoryEntry(appName: nil, bundleID: nil, original: "半句被打断", final: "半句被打断", polish: nil, outcome: .failed)
check(store.append(first) && store.append(second) && store.append(third), "append writes three entries")
check(!store.append(TextHistoryEntry(appName: nil, bundleID: nil, original: "", final: "", polish: nil, outcome: .kept)), "empty utterance is not stored")

let attributes = try! FileManager.default.attributesOfItem(atPath: store.fileURL.path)
let dirAttributes = try! FileManager.default.attributesOfItem(atPath: directory.path)
check((attributes[.posixPermissions] as? Int) == 0o600, "history file is 0600")
check((dirAttributes[.posixPermissions] as? Int) == 0o700, "history directory is 0700")

// A fresh store (as after relaunch) reads the same newest-first entries with every field.
let reopened = TextHistoryStore(directory: directory)
func rounded(_ entry: TextHistoryEntry) -> TextHistoryEntry {
    var copy = entry
    copy.date = Date(timeIntervalSince1970: (entry.date.timeIntervalSince1970 * 1000).rounded() / 1000)
    return copy
}
check(reopened.entries().map(rounded) == [third, second, first].map(rounded), "relaunch keeps every field (ms timestamps), newest first")

// Damaged line in the middle does not lose the rest.
let handle = try! FileHandle(forWritingTo: store.fileURL)
try! handle.seekToEnd(); try! handle.write(contentsOf: Data("{not json\n".utf8)); try! handle.close()
let fourth = TextHistoryEntry(appName: "Mail", bundleID: "com.apple.mail", original: "Ｈｅｌｌｏ Café", final: "Hello café", polish: nil, outcome: .typed)
check(TextHistoryStore(directory: directory).append(fourth), "append after damaged line")
let tolerant = TextHistoryStore(directory: directory).entries()
check(tolerant.map(\.id) == [fourth.id, third.id, second.id, first.id], "damaged line is skipped, other entries survive")

check(TextHistorySearch.filter(tolerant, query: "周四").map(\.id) == [first.id], "search matches final text")
check(TextHistorySearch.filter(tolerant, query: "那个").map(\.id) == [first.id], "search matches original recognition")
check(TextHistorySearch.filter(tolerant, query: "terminal ls").map(\.id) == [second.id], "all terms must match, including app name")
check(TextHistorySearch.filter(tolerant, query: "hello CAFE").map(\.id) == [fourth.id], "case, width and diacritic insensitive")
check(TextHistorySearch.filter(tolerant, query: "   ").count == 4, "blank query shows everything")

check(reopened.delete(id: second.id), "delete one entry")
check(TextHistoryStore(directory: directory).entries().map(\.id) == [fourth.id, third.id, first.id], "delete persists and keeps order")
var notified = false
let token = NotificationCenter.default.addObserver(forName: TextHistoryStore.didChange, object: nil, queue: nil) { _ in notified = true }
check(reopened.clear() && TextHistoryStore(directory: directory).entries().isEmpty && notified, "clear removes everything and notifies")
NotificationCenter.default.removeObserver(token)
print(failures == 0 ? "PASS all text history checks" : "FAILED \(failures)")
exit(failures == 0 ? 0 : 1)
