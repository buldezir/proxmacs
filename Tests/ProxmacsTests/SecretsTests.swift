import Foundation
import XCTest
@testable import Proxmacs

final class SecretsTests: XCTestCase {
    private var file: URL!
    private var savedFile: URL!

    override func setUp() {
        super.setUp()
        file = FileManager.default.temporaryDirectory.appending(path: "proxmacs-secrets-\(UUID().uuidString).json")
        savedFile = Secrets.file
        Secrets.file = file
    }

    override func tearDown() {
        Secrets.file = savedFile
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    func testGetSetDelete() throws {
        XCTAssertNil(Secrets.get("a"))
        try Secrets.set("a", "one")
        XCTAssertEqual(Secrets.get("a"), "one")
        try Secrets.set("b", "two")
        XCTAssertEqual(Secrets.get("b"), "two")
        // Overwrite and delete.
        try Secrets.set("a", "uno")
        XCTAssertEqual(Secrets.get("a"), "uno")
        try Secrets.set("a", nil)
        XCTAssertNil(Secrets.get("a"))
        XCTAssertEqual(Secrets.get("b"), "two")
    }

    func testFileIsOwnerOnly() throws {
        try Secrets.set("a", "one")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testUnreadableFileIsTreatedAsEmpty() throws {
        try Data("not json".utf8).write(to: file)
        XCTAssertNil(Secrets.get("a"))
    }

    /// The whole file is re-encoded on every write, so concurrent saves must not drop
    /// each other's keys.
    func testConcurrentSavesKeepEveryKey() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { try Secrets.set("key\(i)", "value\(i)") }
            }
            try await group.waitForAll()
        }
        let data = try Data(contentsOf: file)
        let all = try JSONDecoder().decode([String: String].self, from: data)
        for i in 0..<50 {
            XCTAssertEqual(all["key\(i)"], "value\(i)")
        }
    }
}
