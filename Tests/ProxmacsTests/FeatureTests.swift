import XCTest
@testable import Proxmacs

final class RetentionTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Backups at 03:00 and 15:00 on each of the last `days` days, newest first.
    private func twiceDaily(days: Int) -> [Date] {
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 15))!
        return (0..<(days * 2)).map { end.addingTimeInterval(-Double($0) * 12 * 3600) }
    }

    func testKeepLastOnly() {
        var policy = BackupPolicy()
        policy.keep = 3
        XCTAssertEqual(Retention.kept(twiceDaily(days: 5), policy: policy, calendar: calendar), [0, 1, 2])
    }

    func testDailyKeepsNewestPerDayAfterLast() {
        var policy = BackupPolicy()
        policy.keep = 1
        policy.keepDaily = 3
        // keep-last takes today's 15:00; its day is covered, so daily keeps the newest of the next 3 days.
        XCTAssertEqual(Retention.kept(twiceDaily(days: 6), policy: policy, calendar: calendar), [0, 2, 4, 6])
    }

    func testWeeklyAndMonthly() {
        var policy = BackupPolicy()
        policy.keep = 0
        policy.keepWeekly = 2
        policy.keepMonthly = 2
        let dates = twiceDaily(days: 60)
        let kept = Retention.kept(dates, policy: policy, calendar: calendar).sorted()
        XCTAssertEqual(kept.count, 4)
        XCTAssertEqual(kept.first, 0, "the newest backup is the newest of its week")
    }

    func testAllZeroKeepsEverything() {
        var policy = BackupPolicy()
        policy.keep = 0
        XCTAssertEqual(Retention.kept(twiceDaily(days: 2), policy: policy).count, 4)
    }
}

final class BackupJobTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testScheduleAndDue() {
        // 2026-10-14 is a Wednesday.
        var job = BackupJob()
        job.hour = 3
        job.minute = 30
        job.days = [1, 3]  // Monday, Wednesday
        job.since = date(1, 0)
        XCTAssertEqual(job.lastOccurrence(before: date(14, 12), calendar: calendar), date(14, 3, 30))
        XCTAssertEqual(job.lastOccurrence(before: date(14, 3), calendar: calendar), date(12, 3, 30))
        XCTAssertEqual(job.nextRun(after: date(14, 12), calendar: calendar), date(19, 3, 30))
        XCTAssertTrue(job.isDue(date(14, 4), calendar: calendar))

        job.lastRun = date(14, 3, 31)
        XCTAssertFalse(job.isDue(date(14, 4), calendar: calendar), "already ran")
        job.lastRun = nil
        XCTAssertFalse(job.isDue(date(14, 23), calendar: calendar), "missed by more than 12 hours")
        job.since = date(14, 10)
        XCTAssertFalse(job.isDue(date(14, 11), calendar: calendar), "created after the occurrence")
        XCTAssertEqual(job.scheduleLabel, "Mon, Wed at 03:30")
        job.days = [1, 2, 3, 4, 5]
        XCTAssertEqual(job.scheduleLabel, "weekdays at 03:30")
    }

    func testSelection() throws {
        var job = BackupJob()
        XCTAssertTrue(job.selects("a"))
        job.selection = .exclude
        job.vms = ["a"]
        XCTAssertFalse(job.selects("a"))
        XCTAssertTrue(job.selects("b"))
        job.selection = .include
        XCTAssertTrue(job.selects("a"))
        XCTAssertFalse(job.selects("b"))
        job.vms = []
        XCTAssertThrowsError(try job.validate())
    }
}

final class GuestParsingTests: XCTestCase {
    func testGuestCounters() {
        let text = """
            Inter-|   Receive                                                |  Transmit
             face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
                lo:    1000      10    0    0    0     0          0         0     1000      10    0    0    0     0       0          0
              enp0s1: 123456     200    0    0    0     0          0         0    65432     100    0    0    0     0       0          0
            MemTotal:        2014712 kB
            MemFree:         1000000 kB
            MemAvailable:    1500000 kB
            HugePages_Total:       0
            """
        let counters = VMMetrics.parseGuest(text)
        XCTAssertEqual(counters?.netIn, 123456)
        XCTAssertEqual(counters?.netOut, 65432)
        XCTAssertEqual(counters?.memTotal, 2014712 * 1024)
        XCTAssertEqual(counters?.memUsed, (2014712 - 1500000) * 1024)
    }

    func testGuestInfo() {
        let text = """
            @os
            Debian GNU/Linux 13 (trixie)
            @kernel
            6.12.111+deb13-cloud-arm64
            @hostname
            pt1
            @uptime
            1234.56 2000.00
            @ip
            [{"ifname":"lo","address":"00:00:00:00:00:00","addr_info":[{"family":"inet","local":"127.0.0.1","prefixlen":8}]},
             {"ifname":"enp0s1","address":"aa:bb:cc:dd:ee:ff","addr_info":[{"family":"inet","local":"192.168.64.11","prefixlen":24},{"family":"inet6","local":"fe80::1","prefixlen":64}]}]
            @df
            Filesystem     Type  1-blocks       Used  Available Capacity Mounted on
            /dev/vda1      ext4  10000000000 1500000000 8000000000      16% /
            /dev/vda15     vfat  130000000   12000000  118000000      10% /boot/efi
            """
        let info = GuestInfo.parse(text)
        XCTAssertEqual(info.os, "Debian GNU/Linux 13 (trixie)")
        XCTAssertEqual(info.hostname, "pt1")
        XCTAssertEqual(info.uptime, 1234.56)
        XCTAssertEqual(info.interfaces.map(\.name), ["enp0s1"])
        XCTAssertEqual(info.interfaces.first?.addresses, ["192.168.64.11/24", "fe80::1/64"])
        XCTAssertEqual(info.filesystems.map(\.mount), ["/", "/boot/efi"])
        XCTAssertEqual(info.filesystems.first?.used, 1500000000)
    }
}

final class CloneSeedTests: XCTestCase {
    func testNewIdentityRegeneratesKeysAndMachineID() {
        let config = CloudInitConfig(user: "debian")
        let normal = CloudInitSeed.userData(hostname: "a", config: config)
        XCTAssertTrue(normal.contains("ssh_deletekeys: false"))
        XCTAssertFalse(normal.contains("systemd-machine-id-setup"))
        XCTAssertTrue(normal.contains("proxmacs-shares.service"))

        let clone = CloudInitSeed.userData(hostname: "b", config: config, newIdentity: true)
        XCTAssertTrue(clone.contains("ssh_deletekeys: true"))
        XCTAssertTrue(clone.contains("systemd-machine-id-setup"))
    }

    func testRunArgumentsCarryDisksSharesAndNested() {
        var meta = VMMeta(name: "x", network: .bridged(interface: "en0"), autostart: false)
        meta.disks = [ExtraDisk(file: "disk1.img")]
        meta.shares = [SharedFolder(name: "docs", path: "/Users/me/My Docs", readOnly: true)]
        meta.nested = true
        let args = LaunchAgent.tartRunArguments(meta: meta, serialPath: "/dev/ttys001")
        XCTAssertTrue(args.contains { $0.hasSuffix("/vms/x/disk1.img") })
        XCTAssertTrue(args.contains("docs:/Users/me/My Docs:ro"))
        XCTAssertTrue(args.contains("--nested"))
        XCTAssertTrue(ExtraDisk.isValidFile("disk12.img"))
        XCTAssertFalse(ExtraDisk.isValidFile("disk.img"))
        XCTAssertFalse(ExtraDisk.isValidFile("../disk1.img"))
    }
}

final class ProvisioningTests: XCTestCase {
    func testScriptRecordsInstanceLast() {
        let config = CloudInitConfig(user: "debian")
        let script = CloudInitSeed.provisionScript(config, instance: "abc-123")
        XCTAssertTrue(script.hasSuffix("echo 'abc-123' > \(CloudInitSeed.provisionedMarker)\n"))
        XCTAssertTrue(script.contains("ssh-keygen -A"), "empty host keys from a cut-short boot are replaced")
        XCTAssertFalse(CloudInitSeed.provisionScript(config).contains(CloudInitSeed.provisionedMarker))
    }

    func testRetryOnlyAfterAnUnfinishedBoot() {
        var state = ProvisionState(instance: "a")
        XCTAssertFalse(state.needsRetry, "never booted")
        state.booted = true
        XCTAssertTrue(state.needsRetry)
        state.done = true
        XCTAssertFalse(state.needsRetry)
        state.done = false
        state.retries = ProvisionState.maxRetries
        XCTAssertFalse(state.needsRetry, "gives up on guests that never report back")
    }
}

final class APIKeyTests: XCTestCase {
    private var dir: URL!
    private var store: APIKeyStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "pmx-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = APIKeyStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCreateAuthenticateRevoke() throws {
        let (key, secret) = try store.create(name: "backup-script")
        XCTAssertTrue(secret.hasPrefix("pmx_"))
        XCTAssertEqual(secret.count, 4 + 64)
        XCTAssertTrue(secret.hasPrefix(key.prefix))
        let stored = try String(contentsOf: store.file, encoding: .utf8)
        XCTAssertFalse(stored.contains(secret), "only a hash is stored")
        let mode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        XCTAssertEqual(store.authenticate(secret)?.id, key.id)
        XCTAssertNotNil(store.lastUsed()[key.id])
        // "z" is outside the hex alphabet, so the one-character near-miss can never
        // come out equal to the original the way "0" does for tokens ending in "0".
        XCTAssertNil(store.authenticate(secret.dropLast() + "z"))
        XCTAssertNil(store.authenticate(""))

        XCTAssertThrowsError(try store.create(name: "backup-script"), "names are unique")
        XCTAssertThrowsError(try store.create(name: "  "))

        try store.remove("backup-script")
        XCTAssertNil(store.authenticate(secret))
        XCTAssertNil(store.lastUsed()[key.id])
        XCTAssertThrowsError(try store.remove("backup-script"))
    }
}
