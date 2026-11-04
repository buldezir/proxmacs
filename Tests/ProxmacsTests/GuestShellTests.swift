import XCTest
@testable import Proxmacs

final class GuestShellTests: XCTestCase {
    /// Stands in for `tart exec -i <vm> sh`: runs the shell on this Mac.
    private func fakeTart() throws -> Tart {
        let url = FileManager.default.temporaryDirectory.appending(path: "fake-tart-\(UUID().uuidString)")
        try "#!/bin/sh\nshift 3\nexec \"$@\"\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Tart(path: url.path)
    }

    func testRunsCommandsInOneShell() async throws {
        let session = try GuestShellSession(tart: try fakeTart(), vm: "vm")
        defer { session.end(ProxmacsError("done")) }

        let first = try await session.run("echo $$; printf 'no newline'", timeout: 5)
        let second = try await session.run("echo $$", timeout: 5)
        let firstLines = first.stdout.split(separator: "\n")
        XCTAssertEqual(firstLines.last, "no newline")
        // Both ran in the same long-lived shell: `$$` is the shell, also in its subshells.
        XCTAssertEqual(firstLines.first, second.stdout.split(separator: "\n").first)
        XCTAssertEqual(first.status, 0)

        let failed = try await session.run("echo out; echo err >&2; exit 3", timeout: 5)
        XCTAssertEqual(failed.stdout, "out\n")
        XCTAssertEqual(failed.status, 3)
        XCTAssertTrue(session.isAlive, "An exit in a command must not end the shell")

        // The command's stdin is /dev/null, not the session's.
        let stdin = try await session.run("cat; echo done", timeout: 5)
        XCTAssertEqual(stdin.stdout, "done\n")
    }

    func testConcurrentCommandsGetTheirOwnOutput() async throws {
        let session = try GuestShellSession(tart: try fakeTart(), vm: "vm")
        defer { session.end(ProxmacsError("done")) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    // Outputs large enough to arrive in several reads.
                    let result = try await session.run("sleep 0.0\(i % 3); yes \(i) | head -n \(i * 2000)", timeout: 10)
                    XCTAssertEqual(result.stdout, String(repeating: "\(i)\n", count: i * 2000))
                }
            }
            try await group.waitForAll()
        }
    }

    func testTimeoutEndsTheSession() async throws {
        let session = try GuestShellSession(tart: try fakeTart(), vm: "vm")
        do {
            _ = try await session.run("sleep 10", timeout: 0.5)
            XCTFail("The command should have timed out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not answer"), error.localizedDescription)
        }
        XCTAssertFalse(session.isAlive)
        do {
            _ = try await session.run("true", timeout: 5)
            XCTFail("An ended session must not run commands")
        } catch {}
    }

    func testTartFailingEndsTheSessionWithItsError() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "failing-tart-\(UUID().uuidString)")
        try "#!/bin/sh\necho 'Failed to connect to the VM using its control socket' >&2\nexit 1\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try GuestShellSession(tart: Tart(path: url.path), vm: "vm")
        do {
            _ = try await session.run("true", timeout: 5)
            XCTFail("The command should have failed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Failed to connect"), error.localizedDescription)
        }
        XCTAssertFalse(session.isAlive)
    }

    func testCrashReason() {
        let crash = """
            guest has stopped the virtual machine due to error: Error Domain=VZErrorDomain Code=1 \
            "The virtual machine stopped unexpectedly." UserInfo={NSLocalizedFailure=Internal Virtualization error.}
            """
        XCTAssertEqual(VMRunner.crashReason(output: "booting\n\(crash)\n", status: 0, signaled: false),
                       "The virtual machine stopped unexpectedly.")
        XCTAssertNil(VMRunner.crashReason(output: "guest has stopped the virtual machine\n", status: 0, signaled: false))
        XCTAssertNil(VMRunner.crashReason(output: "", status: 0, signaled: false))
        XCTAssertEqual(VMRunner.crashReason(output: "", status: 9, signaled: true), "tart was killed by signal 9")
        XCTAssertEqual(VMRunner.crashReason(output: "a\nVM \"x\" is already running!\n", status: 1, signaled: false),
                       "VM \"x\" is already running!")
    }

    /// What tart prints when Virtualization can't lock a macOS VM's disk image that `tart list` is reading, and when
    /// a macOS VM is started again before its old run has ended (the VM limit, or its NVRAM still locked).
    func testRetriesAStartThatFoundTheDiskBusyOrTheVMStillStopping() throws {
        let busy = """
            Error Domain=VZErrorDomain Code=1 "The virtual machine failed to start." UserInfo={NSLocalizedFailure=\
            Internal Virtualization error., NSLocalizedFailureReason=The virtual machine failed to start.}
            """
        let failure = try XCTUnwrap(VMRunner.crashReason(output: busy + "\n", status: 1, signaled: false))
        XCTAssertEqual(VMRunner.startRetryReason(failure: failure, ranFor: 0.5, retries: 0), "its disk image was busy")
        XCTAssertNotNil(VMRunner.startRetryReason(failure: failure, ranFor: 0.5, retries: VMRunner.maxStartRetries - 1))
        XCTAssertNil(VMRunner.startRetryReason(failure: failure, ranFor: 0.5, retries: VMRunner.maxStartRetries),
                     "gives up, and the failure is reported as before")
        XCTAssertNil(VMRunner.startRetryReason(failure: failure, ranFor: 120, retries: 0), "not a VM that ran a while")

        let limit = try XCTUnwrap(VMRunner.crashReason(
            output: "The number of VMs exceeds the system limit (other running VMs: mac1)\n", status: 1, signaled: false))
        XCTAssertEqual(VMRunner.startRetryReason(failure: limit, ranFor: 0.3, retries: 0), "its previous run hadn't ended yet")
        let nvram = try XCTUnwrap(VMRunner.crashReason(output: """
            Error Domain=VZErrorDomain Code=2 "Failed to lock auxiliary storage." UserInfo={NSLocalizedFailure=\
            Invalid virtual machine configuration.}

            """, status: 1, signaled: false))
        XCTAssertEqual(VMRunner.startRetryReason(failure: nvram, ranFor: 0.3, retries: 0), "its previous run hadn't ended yet")

        XCTAssertNil(VMRunner.startRetryReason(failure: "The virtual machine stopped unexpectedly.", ranFor: 0.5, retries: 0))
        XCTAssertNil(VMRunner.startRetryReason(failure: "VM \"x\" is already running!", ranFor: 0.5, retries: 0))
    }
}
