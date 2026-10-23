import Foundation
import XCTest
@testable import Proxmacs

final class VNCCredentialsTests: XCTestCase {
    private var file: URL!
    private var savedFile: URL!

    override func setUp() {
        super.setUp()
        file = FileManager.default.temporaryDirectory.appending(path: "proxmacs-vnc-secrets-\(UUID().uuidString).json")
        savedFile = Secrets.file
        Secrets.file = file
    }

    override func tearDown() {
        Secrets.file = savedFile
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    func testLoadSaveClear() throws {
        XCTAssertNil(VNCCredentials.load("web1"))
        try VNCCredentials.save("web1", username: "alice", password: "s3cret")
        XCTAssertEqual(VNCCredentials.load("web1"),
                       VNCCredentials.Credentials(username: "alice", password: "s3cret"))
        try VNCCredentials.clear("web1")
        XCTAssertNil(VNCCredentials.load("web1"))
    }

    func testLoadIgnoresAnEmptyPair() throws {
        try VNCCredentials.save("web1", username: "alice", password: "s3cret")
        try Secrets.set(VNCCredentials.passKey("web1"), "")
        XCTAssertNil(VNCCredentials.load("web1"))
    }

    func testClearAlsoDropsTheLegacyPassword() throws {
        try Secrets.set(VNCCredentials.legacyKey("web1"), "old-random-password")
        try VNCCredentials.save("web1", username: "alice", password: "s3cret")
        try VNCCredentials.clear("web1")
        XCTAssertNil(Secrets.get(VNCCredentials.legacyKey("web1")))
    }

    func testClearLeavesOtherVMsAlone() throws {
        try VNCCredentials.save("web1", username: "alice", password: "one")
        try VNCCredentials.save("web2", username: "bob", password: "two")
        try VNCCredentials.clear("web1")
        XCTAssertNil(VNCCredentials.load("web1"))
        XCTAssertEqual(VNCCredentials.load("web2"),
                       VNCCredentials.Credentials(username: "bob", password: "two"))
    }
}

/// kickstart runs as argv through `tart exec`, where every argument shows up in `ps`.
final class ScreenSharingSetupTests: XCTestCase {
    func testActivationCommandsAreFixedAndCarryNoSecret() {
        XCTAssertEqual(ScreenSharingSetup.activationCommand(), [
            "/usr/bin/sudo", "-n", ScreenSharingSetup.kickstart,
            "-activate", "-configure", "-access", "-on", "-restart", "-agent",
        ])
        // Legacy VNC auth, left on by earlier builds of this branch, is switched off again.
        XCTAssertEqual(ScreenSharingSetup.legacyDisableCommand(), [
            "/usr/bin/sudo", "-n", ScreenSharingSetup.kickstart,
            "-configure", "-clientopts", "-setvnclegacy", "-vnclegacy", "no",
        ])
        // Observe+control, not -all: a display session must not be able to delete files.
        XCTAssertEqual(ScreenSharingSetup.accessCommand(), [
            "/usr/bin/sudo", "-n", ScreenSharingSetup.kickstart,
            "-configure", "-allowAccessFor", "-allUsers", "-privs", "-ControlObserve",
        ])
        XCTAssertEqual(ScreenSharingSetup.policyCommand(), [
            "/usr/bin/defaults", "read", "/Library/Preferences/com.apple.RemoteManagement",
        ])
        // "Is Screen Sharing up?" asked of the guest, because privacy makes a closed port
        // look unreachable from here. `nc -z` answers with its exit status alone.
        XCTAssertEqual(ScreenSharingSetup.probeCommand(), [
            "/usr/bin/nc", "-z", "127.0.0.1", "5900",
        ])
    }

    /// `-access -on` alone leaves every account at Remote Management level 0, where the
    /// guest rejects every sign-in. That is the one state we are allowed to repair.
    func testGrantsAccessOnlyWhereNobodyHasAny() {
        XCTAssertTrue(ScreenSharingSetup.needsAccessGrant("""
        {
            ARD_AllLocalUsers = 1;
            ARD_AllLocalUsersPrivs = 0;
        }
        """))
        // Nothing set at all is the same thing.
        XCTAssertTrue(ScreenSharingSetup.needsAccessGrant("""
        {
            allowInsecureDH = 1;
        }
        """))
        // Already granted: leave it alone.
        XCTAssertFalse(ScreenSharingSetup.needsAccessGrant("""
        {
            ARD_AllLocalUsers = 1;
            ARD_AllLocalUsersPrivs = 2;
        }
        """))
        // A "specified users" policy is deliberate, even if it currently grants nothing.
        XCTAssertFalse(ScreenSharingSetup.needsAccessGrant("""
        {
            ARD_AllLocalUsers = 0;
            ARD_AllLocalUsersPrivs = 0;
        }
        """))
    }
}
