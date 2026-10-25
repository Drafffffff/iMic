import Foundation

/// 保留已输入的共同前缀，只替换尾部；计数按字素簇而非 UTF-16 单元。
struct TextRevision {
    let deleteCount: Int
    let insertion: String

    init(from previous: String, to next: String) {
        var oldIndex = previous.startIndex
        var newIndex = next.startIndex
        while oldIndex != previous.endIndex, newIndex != next.endIndex,
              previous[oldIndex] == next[newIndex] {
            previous.formIndex(after: &oldIndex)
            next.formIndex(after: &newIndex)
        }
        deleteCount = previous.distance(from: oldIndex, to: previous.endIndex)
        insertion = String(next[newIndex...])
    }
}
