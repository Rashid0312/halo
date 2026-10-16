import Foundation

public struct InstalledApp: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let path: String
    public let alternateNames: [String]
    public init(id: String, name: String, path: String, alternateNames: [String] = []) {
        self.id = id; self.name = name; self.path = path; self.alternateNames = alternateNames
    }
}

public enum AppResolution: Equatable, Sendable {
    case match(InstalledApp), suggestions([InstalledApp]), missing
}

public enum AppResolver {
    // Spoken variants are tied to a real installed app, never a guessed executable path.
    private static let knownAliases = [
        "streamio": "Stremio", "streamo": "Stremio", "stream eo": "Stremio", "strem io": "Stremio",
        "chrome": "Google Chrome", "vscode": "Visual Studio Code", "vs code": "Visual Studio Code",
        "settings": "System Settings", "system preferences": "System Settings",
        "word": "Microsoft Word", "excel": "Microsoft Excel", "powerpoint": "Microsoft PowerPoint",
    ]

    public static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    public static func resolve(_ query: String, apps: [InstalledApp], aliases: [String: String] = [:]) -> AppResolution {
        let key = normalized(query.replacingOccurrences(of: #"\.app$"#, with: "", options: [.regularExpression, .caseInsensitive]))
        guard !key.isEmpty else { return .missing }
        // Actual installed names have priority over user aliases to a different app.
        let exact = apps.filter { app in
            ([app.name, app.id] + app.alternateNames).contains { normalized($0) == key }
        }
        if exact.count == 1 { return .match(exact[0]) }
        if !exact.isEmpty { return .suggestions(exact) }
        if let id = aliases.first(where: { normalized($0.key) == key })?.value,
           let app = apps.first(where: { $0.id == id }) { return .match(app) }
        if let target = knownAliases.first(where: { normalized($0.key) == key })?.value {
            let matches = apps.filter { normalized($0.name) == normalized(target) || $0.alternateNames.contains { normalized($0) == normalized(target) } }
            if matches.count == 1 { return .match(matches[0]) }
            if !matches.isEmpty { return .suggestions(matches) }
        }
        // Near matches require a real app selection, never an automatic launch.
        let ranked = apps.compactMap { app -> (InstalledApp, Int)? in
            let names = ([app.name] + app.alternateNames).map(normalized)
            let distance = names.map { editDistance(key, $0) }.min() ?? 1000
            let partial = names.contains { key.count >= 3 && $0.contains(key) }
            guard partial || distance <= max(1, min(3, key.count / 3)) else { return nil }
            return (app, partial ? 0 : distance)
        }.sorted { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 < $1.1 }
        return ranked.isEmpty ? .missing : .suggestions(Array(ranked.prefix(4).map(\.0)))
    }

    public static func speechVocabulary(apps: [InstalledApp], aliases: [String: String] = [:]) -> [String] {
        let installed = Set(apps.map(\.id))
        let known = knownAliases.compactMap { spoken, target in
            apps.contains { normalized($0.name) == normalized(target) } ? spoken : nil
        }
        let names = apps.flatMap { [$0.name] + $0.alternateNames }
        let custom = aliases.filter { installed.contains($0.value) }.map(\.key)
        var seen = Set<String>()
        // Common problem names and custom corrections first if there are many apps.
        return (custom + known + names).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(150).map { $0 }
    }

    public static func launchTarget(in input: String) -> String? {
        let pattern = #"^(?:(?:hey\s+)?mercy[,!\s]+)?(?:(?:can|could|would)\s+you\s+)?(?:please\s+)?(?:open|launch|start|switch\s+to|bring\s+up|activate)\s+(.+?)(?:\s+please)?[.!?]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let range = Range(match.range(at: 1), in: input) else { return nil }
        let target = input[range].trimmingCharacters(in: .whitespacesAndNewlines)
        // Leave compound requests to the model; don't silently execute only half.
        if target.range(of: #"\s(?:and|then)\s|https?://|/"#, options: .regularExpression) != nil { return nil }
        return target
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let left = Array(a), right = Array(b)
        guard abs(left.count - right.count) <= 3 else { return 1000 }
        var previous = Array(0...right.count)
        for (i, letter) in left.enumerated() {
            var next = [i + 1]
            for (j, other) in right.enumerated() {
                next.append(min(next[j] + 1, previous[j + 1] + 1, previous[j] + (letter == other ? 0 : 1)))
            }
            previous = next
        }
        return previous.last ?? 0
    }
}
