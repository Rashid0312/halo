import Foundation
import HaloCore

@MainActor
enum NativeChecks {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func files(_ tools: MacTools) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("halo-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("sample.txt")
        try Data("original".utf8).write(to: fixture)
        func arguments(_ values: [String: String]) throws -> String {
            String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        }
        func object(_ result: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] ?? [:]
        }
        let read = try object(await tools.execute(name: "read_file", arguments: arguments(["path": fixture.path])))
        guard read["content"] as? String == "original" else { throw Failure("Native text read failed") }
        let list = try object(await tools.execute(name: "list_files", arguments: arguments(["path": root.path])))
        guard (list["entries"] as? [[String: String]])?.contains(where: { $0["name"] == "sample.txt" }) == true else { throw Failure("Native folder listing failed") }

        let change = try arguments(["path": fixture.path, "content": "replacement"])
        let denied = Task { try await tools.execute(name: "write_file", arguments: change) }
        let first = try await waitForApproval(tools)
        guard first.path == fixture.path && first.preview == "replacement" else { throw Failure("Approval preview differs from the action") }
        tools.resolve(id: first.id, allow: false)
        let denial = try object(await denied.value)
        guard denial["denied"] as? Bool == true,
              try String(contentsOf: fixture, encoding: .utf8) == "original" else { throw Failure("Denied write changed the file") }

        let allowed = Task { try await tools.execute(name: "write_file", arguments: change) }
        let second = try await waitForApproval(tools)
        tools.resolve(id: second.id, allow: true)
        let success = try object(await allowed.value)
        guard success["ok"] as? Bool == true,
              try String(contentsOf: fixture, encoding: .utf8) == "replacement" else { throw Failure("Approved write did not complete") }

        let cancelled = Task { try await tools.execute(name: "write_file", arguments: change) }
        _ = try await waitForApproval(tools)
        cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure("Cancelled approval did not throw") }
        catch is CancellationError {}
        guard tools.approval == nil, try String(contentsOf: fixture, encoding: .utf8) == "replacement" else {
            throw Failure("Cancelled approval remained active or changed the file")
        }
        let invalid = try object(await tools.execute(name: "read_file", arguments: arguments(["path": "/dev/zero"])))
        guard invalid["ok"] as? Bool == false else { throw Failure("Special-file read was not rejected") }
        print("PASS: native folder/text reads, exact write preview, denial, approval, cancellation, and special-file rejection")
    }

    private static func waitForApproval(_ tools: MacTools) async throws -> MacTools.Approval {
        for _ in 0..<100 {
            if let approval = tools.approval { return approval }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure("Approval did not appear")
    }
}
