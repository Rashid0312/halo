import Foundation

/// Swaps private values for stable labels ([EMAIL_1], [PERSON_2]) before text
/// reaches the cloud model, and swaps them back on this Mac just before a
/// connector runs. Uses Scrubber's patterns, plus names registered by the app.
/// Like Scrubber it cannot recognise unregistered names or free-form text.
public final class PIIVault: @unchecked Sendable {
    public struct UnknownLabel: LocalizedError {
        public let label: String
        public var errorDescription: String? { "\(label) is not a value Halo labelled; use the label exactly as it appeared." }
    }

    private let lock = NSLock()
    private var labels: [String: String] = [:]   // real value → label
    private var values: [String: String] = [:]   // label → real value
    private var counts: [String: Int] = [:]
    private var names: [String] = []
    private static let labelPattern = try! NSRegularExpression(pattern: #"\[(EMAIL|PHONE|CARD|SECRET|PERSON)_\d+\]"#)
    private static let kinds = ["<email>": "EMAIL", "<secret>": "SECRET", "Bearer <secret>": "SECRET", "<phone>": "PHONE"]

    public init() {}

    /// Adds a person's name to recognise (the user's own, or contacts the privacy gate finds).
    public func register(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        lock.lock(); defer { lock.unlock() }
        if !names.contains(trimmed) { names.append(trimmed); names.sort { $0.count > $1.count } }
    }

    /// Forgets every label, e.g. when a conversation is cleared.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        labels = [:]; values = [:]; counts = [:]
    }

    /// Labels plain text, or only the string values when `text` is JSON.
    public func label(_ text: String) -> String {
        mapJSON(text) { self.labelText($0) } ?? labelText(text)
    }

    /// Puts real values back. Throws on a label this vault never issued, so a
    /// guessed placeholder is never sent to a service as if it were real.
    public func restore(_ text: String) throws -> String {
        var failure: UnknownLabel?
        let restore: (String) -> String = { text in
            do { return try self.restoreText(text) } catch { failure = error as? UnknownLabel; return text }
        }
        let result = mapJSON(text, restore) ?? restore(text)
        if let failure { throw failure }
        return result
    }

    private func labelText(_ text: String) -> String {
        lock.lock(); defer { lock.unlock() }
        var text = text
        for name in names {
            let pattern = try! NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b")
            text = replace(pattern, in: text) { _ in "PERSON" }
        }
        for (rule, template) in Scrubber.rules {
            guard let kind = Self.kinds[template] else { continue }
            text = replace(rule, in: text) { _ in kind }
        }
        text = replace(Scrubber.digitRun, in: text) { Scrubber.luhn($0.filter(\.isNumber)) ? "CARD" : nil }
        return text
    }

    /// Replaces each match with its label; `kind` returns nil to keep a match.
    private func replace(_ pattern: NSRegularExpression, in text: String, kind: (String) -> String?) -> String {
        var text = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let value = String(text[range])
            guard Self.labelPattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) == nil,
                  let kind = kind(value) else { continue }
            text.replaceSubrange(range, with: labelFor(value, kind: kind))
        }
        return text
    }

    private func labelFor(_ value: String, kind: String) -> String {
        if let existing = labels[value] { return existing }
        let next = (counts[kind] ?? 0) + 1
        counts[kind] = next
        let label = "[\(kind)_\(next)]"
        labels[value] = label; values[label] = value
        return label
    }

    private func restoreText(_ text: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        var text = text
        for match in Self.labelPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let label = String(text[range])
            guard let value = values[label] else { throw UnknownLabel(label: label) }
            text.replaceSubrange(range, with: value)
        }
        return text
    }

    private func mapJSON(_ text: String, _ transform: @escaping (String) -> String) -> String? {
        guard let first = text.first, first == "{" || first == "[",
              let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        func map(_ value: Any) -> Any {
            switch value {
            case let text as String: transform(text)
            case let array as [Any]: array.map(map)
            case let object as [String: Any]: object.mapValues(map)
            default: value
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: map(value), options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
