import Foundation

/// A wake phrase is not a request. Wait for request text before using the
/// normal speech endpoint; otherwise leave time to start speaking.
public struct RequestEndpoint: Sendable {
    private var elapsed = 0
    private var lastSpeech = 0
    private var confirmedRequest = false
    public init() {}
    public mutating func confirmRequest() { confirmedRequest = true }

    public mutating func observe(sampleCount: Int, speechDetected: Bool) -> Bool {
        elapsed += max(0, sampleCount)
        if speechDetected { lastSpeech = elapsed }
        let quiet = elapsed - lastSpeech >= 11200 // 0.7 s after VAD releases speech
        if elapsed >= 320000 { return true } // 20 s hard request limit
        if confirmedRequest { return quiet }
        return elapsed >= 128000 && quiet // 8 s to begin after the wake phrase
    }
}

public enum WakeTranscript {
    public static func request(from text: String) -> String? {
        // Merci is a common orthographic rendering of the same spoken name;
        // this is used only after the independent local keyword detector fired.
        guard let match = text.range(of: #"\b(?:hey[\s,]+)?merc[yi]\b[\s,.!?]*"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[match.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
