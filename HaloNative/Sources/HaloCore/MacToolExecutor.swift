import Foundation

public protocol MacToolExecutor: Sendable {
    func definitions() async throws -> Data
    func execute(name: String, arguments: String) async throws -> String
}

public struct ToolFragment: Decodable, Sendable {
    public var index: Int
    public var id: String?
    public var function: Function?
    public struct Function: Decodable, Sendable {
        public var name: String?
        public var arguments: String?
    }
}

public struct ToolCall: Sendable {
    public var id = ""
    public var name = ""
    public var arguments = ""
    public init() {}
    public mutating func append(_ fragment: ToolFragment) {
        if let id = fragment.id { self.id = id }
        name += fragment.function?.name ?? ""
        arguments += fragment.function?.arguments ?? ""
    }
}
