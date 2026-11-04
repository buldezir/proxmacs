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

    /// From a macOS 27 guest (some vm_stat lines and netstat address rows left out).
    func testMacOSGuestCounters() {
        let text = """
            @mem
            8589934592
            Mach Virtual Memory Statistics: (page size of 16384 bytes)
            Pages free:                                     3928.
            Pages active:                                 205818.
            Pages wired down:                              70053.
            Pages purgeable:                                4764.
            "Translation faults":                        3429437.
            File-backed pages:                            266927.
            Anonymous pages:                              159085.
            Pages occupied by compressor:                  23605.
            @net
            Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
            lo0        16384 <Link#1>                           531     0     107363      531     0     107363     0
            lo0        16384 127           127.0.0.1            531     -     107363      531     -     107363     -
            gif0*      1280  <Link#2>                             0     0          0        0     0          0     0
            en0        1500  <Link#6>    7a:67:c6:09:af:5f    20527     0    8057118     5270     0    2270074     0
            en0        1500  192.168.178   192.168.178.32     20527     -    8057118     5270     -    2270074     -
            utun0      1380  <Link#8>                             0     0          0        2     0        200     0
            utun4      1280  <Link#12>                         1426     0      89232     1299     0    1392143     0
            utun4      1280  100.86.96.95/ 100.86.96.95        1426     -      89232     1299     -    1392143     -
            """
        let counters = VMMetrics.parseMacOSGuest(text)
        XCTAssertEqual(counters?.memTotal, 8589934592)
        XCTAssertEqual(counters?.memUsed, (159085 - 4764 + 70053 + 23605) * 16384, "app + wired + compressed, like Activity Monitor")
        XCTAssertEqual(counters?.netIn, 8057118 + 89232, "every interface's link row but loopback, each once")
        XCTAssertEqual(counters?.netOut, 2270074 + 200 + 1392143)
        XCTAssertNil(VMMetrics.parseMacOSGuest("@mem\n8589934592\n@net\n"), "no vm_stat, no figure")
    }

    /// The counters come from tools that the macOS test machine has too.
    func testMacOSGuestScriptRunsOnMacOS() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", VMMetrics.macOSGuestScript], timeout: 30)
        XCTAssertTrue(result.succeeded, "status \(result.status): \(result.stderr)")
        let counters = try XCTUnwrap(VMMetrics.parseMacOSGuest(result.stdout))
        XCTAssertEqual(counters.memTotal, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(counters.memUsed, 0)
        XCTAssertLessThanOrEqual(counters.memUsed, counters.memTotal)
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

    /// From a macOS 27 guest (MAC addresses and the asset volume shortened), plus a shared folder.
    func testMacOSGuestInfo() {
        let text = """
            @os
            macOS 27.0.1 (26A434)
            @kernel
            27.0.0
            @hostname
            macos-vm2
            @uptime
            2456
            @ifconfig
            lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
            \tinet 127.0.0.1 netmask 0xff000000
            \tinet6 ::1 prefixlen 128
            \tinet6 fe80::1%lo0 prefixlen 64 scopeid 0x1
            gif0: flags=8010<POINTOPOINT,MULTICAST> mtu 1280
            anpi0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \tether 3e:00:00:00:00:01
            \tstatus: inactive
            en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \toptions=463<RXCSUM,TXCSUM,TSO4,TSO6,CHANNEL_IO>
            \tether 7a:00:00:00:00:02
            \tinet6 fe80::188c:5c7a:6d0e:a7bc%en0 prefixlen 64 secured scopeid 0x6
            \tinet6 fd2d:d0e2:9a6f:0:1016:5faf:7d6b:d5f8 prefixlen 64 autoconf secured
            \tinet 192.168.178.32 netmask 0xffffff00 broadcast 192.168.178.255
            \tstatus: active
            utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
            \tinet6 fe80::5e57:4531:d7f:e391%utun0 prefixlen 64 scopeid 0x8
            utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
            \tinet 100.86.96.95 --> 100.86.96.95 netmask 0xffffffff
            \tinet6 fd7a:115c:a1e0::5038:6060 --> fd7a:115c:a1e0::5038:6060 prefixlen 128
            @mount
            /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
            devfs on /dev (devfs, local, nobrowse)
            /dev/disk3s6 on /System/Volumes/VM (apfs, local, noexec, journaled, noatime, nobrowse)
            /dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled, nobrowse, root data)
            map auto_home on /System/Volumes/Data/home (autofs, automounted, nobrowse)
            /dev/disk5s1 on /System/Library/AssetsV2/x.asset/.AssetData (apfs, sealed, local, read-only, journaled, nobrowse)
            /dev/disk0 on /Volumes/My Shared Files (AppleVirtIOFS, local, nodev, nosuid, automounted)
            @dfk
            Filesystem     1024-blocks     Used Available Capacity  Mounted on
            /dev/disk3s1s1   189557616 13333684 146802204     9%    /
            /dev/disk3s6     189557616       20 146802204     1%    /System/Volumes/VM
            /dev/disk3s5     189557616 17272836 146802204    11%    /System/Volumes/Data
            /dev/disk5s1          4096      676      3076    19%    /System/Library/AssetsV2/x.asset/.AssetData
            /dev/disk0         1000000    10000    990000     1%    /Volumes/My Shared Files
            """
        let info = GuestInfo.parseMacOS(text)
        XCTAssertEqual(info.os, "macOS 27.0.1 (26A434)")
        XCTAssertEqual(info.kernel, "27.0.0")
        XCTAssertEqual(info.hostname, "macos-vm2")
        XCTAssertEqual(info.uptime, 2456)
        XCTAssertEqual(info.interfaces.map(\.name), ["en0", "utun4"], "no loopback, and none with only a link-local address")
        XCTAssertEqual(info.interfaces.first?.mac, "7a:00:00:00:00:02")
        XCTAssertEqual(info.interfaces.first?.addresses,
                       ["fe80::188c:5c7a:6d0e:a7bc/64", "fd2d:d0e2:9a6f:0:1016:5faf:7d6b:d5f8/64", "192.168.178.32/24"])
        XCTAssertEqual(info.interfaces.last?.addresses, ["100.86.96.95/32", "fd7a:115c:a1e0::5038:6060/128"])
        XCTAssertNil(info.interfaces.last?.mac)
        XCTAssertEqual(info.filesystems.map(\.mount), ["/"], "no nobrowse system volumes, no shared folder")
        XCTAssertEqual(info.filesystems.first?.type, "apfs")
        XCTAssertEqual(info.filesystems.first?.size, 189557616 * 1024)
        XCTAssertEqual(info.filesystems.first?.used, (189557616 - 146802204) * 1024, "the container's use, not the system volume's")
    }

    /// The report runs in the guest; macOS hosts run the same tools, so check it against the real ones here.
    func testMacOSScriptRunsOnMacOS() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", GuestInfo.macOSScript], timeout: 30)
        XCTAssertTrue(result.succeeded, "status \(result.status): \(result.stderr)")
        let info = GuestInfo.parseMacOS(result.stdout)
        XCTAssertTrue(info.os?.hasPrefix("macOS ") == true, info.os ?? "no OS")
        XCTAssertNotNil(info.kernel)
        XCTAssertGreaterThan(info.uptime ?? 0, 0)
        XCTAssertTrue(info.filesystems.contains { $0.mount == "/" && $0.used > 0 && $0.used <= $0.size },
                      "\(info.filesystems.map(\.mount))")
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
        let args = LaunchAgent.tartRunArguments(meta: meta, os: .linux, serialPath: "/dev/ttys001")
        XCTAssertTrue(args.contains { $0.hasSuffix("/vms/x/disk1.img") })
        XCTAssertTrue(args.contains("docs:/Users/me/My Docs:ro"))
        XCTAssertTrue(args.contains("--nested"))
        XCTAssertTrue(ExtraDisk.isValidFile("disk12.img"))
        XCTAssertFalse(ExtraDisk.isValidFile("disk.img"))
        XCTAssertFalse(ExtraDisk.isValidFile("../disk1.img"))
    }

    func testMacOSGuestsBootWithoutTheSeed() throws {
        let name = "proxmacs-test-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(at: Paths.vmDir(name), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: Paths.vmDir(name)) }
        try Data().write(to: Paths.seedISO(name))

        let meta = VMMeta(name: name, network: .nat, autostart: false)
        let seed = "\(Paths.seedISO(name).path):ro"
        XCTAssertTrue(LaunchAgent.tartRunArguments(meta: meta, os: .linux, serialPath: "/dev/ttys001").contains(seed))
        XCTAssertTrue(LaunchAgent.tartRunArguments(meta: meta, os: nil, serialPath: "/dev/ttys001").contains(seed))
        XCTAssertFalse(LaunchAgent.tartRunArguments(meta: meta, os: .darwin, serialPath: "/dev/ttys001").contains(seed),
                       "a seed left by an older clone isn't attached to a macOS guest")
    }
}

final class GuestOSTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "pmx-os-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func config(_ json: String) throws -> URL {
        let file = dir.appending(path: "\(UUID().uuidString).json")
        try Data(json.utf8).write(to: file)
        return file
    }

    func testReadsTheOSTartRecorded() throws {
        XCTAssertEqual(GuestOS.read(try config(#"{"version": 1, "os": "darwin", "cpuCount": 4}"#)), .darwin)
        XCTAssertEqual(GuestOS.read(try config(#"{"version": 1, "os": "linux"}"#)), .linux)
        XCTAssertNil(GuestOS.read(try config(#"{"version": 1}"#)))
        XCTAssertNil(GuestOS.read(try config(#"{"os": "windows"}"#)))
        XCTAssertNil(GuestOS.read(dir.appending(path: "missing.json")))
    }

    /// macOS has no `ip`: its address comes from `ifconfig`, where a VPN tunnel can follow Tart's en0.
    func testMacOSGuestAddressFromIfconfig() {
        let ifconfig = """
            lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
            \tinet 127.0.0.1 netmask 0xff000000
            \tinet6 ::1 prefixlen 128
            gif0: flags=8010<POINTOPOINT,MULTICAST> mtu 1280
            en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \tether 7a:00:00:00:00:01
            \tinet6 fe80::188c:5c7a:6d0e:a7bc%en0 prefixlen 64 secured scopeid 0x6
            \tinet 192.168.178.32 netmask 0xffffff00 broadcast 192.168.178.255
            \tstatus: active
            utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
            \tinet 100.86.96.95 --> 100.86.96.95 netmask 0xffffffff
            """
        XCTAssertEqual(GuestInfo.ifconfigAddress(ifconfig), "192.168.178.32")
        XCTAssertNil(GuestInfo.ifconfigAddress("en0: flags=8863<UP>\n\tinet 169.254.10.2 netmask 0xffff0000\n"),
                     "a link-local address isn't one to connect to")
        XCTAssertNil(GuestInfo.ifconfigAddress("lo0: flags=8049<UP,LOOPBACK>\n\tinet 127.0.0.1 netmask 0xff000000\n"))
        XCTAssertNil(GuestInfo.ifconfigAddress(""))
    }

    /// With Tart's MAC address, the card is found by it, whatever comes first: here Internet Sharing's bridge.
    func testMacOSGuestAddressByTartsMAC() {
        let ifconfig = """
            lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
            \tinet 127.0.0.1 netmask 0xff000000
            bridge100: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \tether 3e:00:00:00:00:64
            \tinet 192.168.2.1 netmask 0xffffff00 broadcast 192.168.2.255
            en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \tether 0a:67:c6:09:af:5f
            \tinet6 fd2d:d0e2:9a6f:0:1016:5faf:7d6b:d5f8 prefixlen 64 autoconf secured
            \tinet 192.168.178.32 netmask 0xffffff00 broadcast 192.168.178.255
            """
        XCTAssertEqual(GuestInfo.ifconfigAddress(ifconfig), "192.168.2.1", "without the MAC: the first address")
        XCTAssertEqual(GuestInfo.ifconfigAddress(ifconfig, mac: "a:67:C6:9:af:5f"), "192.168.178.32", "same card, written differently")
        XCTAssertEqual(GuestInfo.ifconfigAddress(ifconfig, mac: "02:00:00:00:00:01"), "192.168.2.1", "no card with it: the first address")
        XCTAssertEqual(TartConfig.macBytes("0A:67:c6:09:AF:5f"), [0x0a, 0x67, 0xc6, 0x09, 0xaf, 0x5f])
        XCTAssertNil(TartConfig.macBytes("0a:67:c6:09:af"))
        XCTAssertNil(TartConfig.macBytes("0a:67:c6:09:af:zz"))
    }

    /// Proxmacs remembers the OS, so a macOS VM is still one while Tart's config.json can't be read.
    func testRemembersTheOS() throws {
        let name = "proxmacs-test-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(at: Paths.vmDir(name)) }
        XCTAssertNil(GuestOS.of(name), "never seen")
        var meta = VMMeta(name: name, network: .nat, autostart: false)
        meta.os = .darwin
        try meta.save()
        XCTAssertEqual(GuestOS.of(name), .darwin, "no config.json, so the remembered OS")

        let saved = try XCTUnwrap(VMMeta.load(name))
        XCTAssertEqual(saved.os, .darwin)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Paths.metaFile(name))) as? [String: Any])
        json["os"] = "windows"
        let unknown = try JSONDecoder.proxmacs.decode(VMMeta.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(unknown.os, "an OS this version doesn't know is none")
        XCTAssertEqual(unknown.name, name, "and the rest of the settings still load")
    }

    /// Checked as text only: run here, it would rename the test machine.
    func testMacOSCloneIdentityScript() {
        let script = VMRunner.macOSIdentityScript(hostName: "mac-clone-2")
        for key in ["ComputerName", "LocalHostName", "HostName"] {
            XCTAssertTrue(script.contains("/usr/bin/sudo -n /usr/sbin/scutil --set \(key) 'mac-clone-2'"), key)
        }
        XCTAssertTrue(script.contains("rm -f /etc/ssh/ssh_host_* && /usr/bin/ssh-keygen -A"))
        XCTAssertTrue(script.hasPrefix("{ ") && script.hasSuffix("; } 2>&1"), "errors reach the run log")
        XCTAssertEqual(script.components(separatedBy: " && ").count, 5, "stops at the first step that fails")
    }

    /// A clone gets a new MAC address, and a macOS clone a new machine identifier (serial number) too.
    func testCloneSetArguments() {
        XCTAssertEqual(Tart.setArguments("c", randomMAC: true, randomSerial: true), ["set", "c", "--random-mac", "--random-serial"])
        XCTAssertEqual(Tart.setArguments("c", randomMAC: true), ["set", "c", "--random-mac"])
        XCTAssertEqual(Tart.setArguments("c", cpu: 4, diskSizeGB: 40), ["set", "c", "--cpu", "4", "--disk-size", "40"])
    }

    /// A macOS guest has no systemctl, and `tart exec` hangs if the guest goes down under it.
    func testRebootCommand() throws {
        XCTAssertEqual(GuestOS.rebootCommand(.linux), ["systemctl", "reboot"])
        XCTAssertEqual(GuestOS.rebootCommand(nil), ["systemctl", "reboot"])
        let mac = GuestOS.rebootCommand(.darwin)
        XCTAssertEqual(Array(mac.prefix(2)), ["/bin/sh", "-c"])
        let script = try XCTUnwrap(mac.last)
        XCTAssertTrue(script.hasPrefix("/usr/bin/sudo -n /usr/bin/true && "), "fails, rather than claims a reboot, without passwordless sudo")
        XCTAssertTrue(script.contains("sleep 2; /usr/bin/sudo -n /sbin/shutdown -r now"))
        XCTAssertTrue(script.hasSuffix("& }"), "in the background, so the agent call returns first")
    }

    func testSSHUserOfAMacOSGuestIsItsScreenSharingAccount() {
        var meta = VMMeta(name: "mac", network: .nat, autostart: false)
        var item = VMItem(meta: meta, state: "running", ip: "192.168.64.5")
        item.os = .darwin
        item.remoteLogin = true
        XCTAssertNil(item.sshUser, "not the cloud-init default")
        item.screenSharingUser = "admin"
        XCTAssertEqual(item.sshUser, "admin")
        item.remoteLogin = false
        XCTAssertNil(item.sshUser, "no hint while Remote Login is off")
        item.remoteLogin = nil
        XCTAssertNil(item.sshUser, "nor before it's been checked")

        meta.cloudInit = CloudInitConfig(user: "ubuntu")
        item = VMItem(meta: meta, state: "running", ip: "192.168.64.6")
        item.os = .linux
        item.screenSharingUser = "admin"
        XCTAssertEqual(item.sshUser, "ubuntu")
        item.os = nil
        XCTAssertEqual(item.sshUser, "ubuntu", "storage offline: still a Linux guest as far as anyone knows")
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

    func testLLMsTxtCarriesTheAPIReference() {
        let text = LLMsTxt.text
        XCTAssertTrue(text.hasPrefix("# Proxmacs\n\n> "), "llms.txt starts with a title and a summary")
        XCTAssertTrue(text.contains("\n## API reference\n"))
        XCTAssertTrue(text.contains("`POST /api/vms/:name/start`"), "docs/API.md follows")
        XCTAssertFalse(text.contains("# Proxmacs web API"), "under one title")
    }
}
