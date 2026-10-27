import Foundation

/// Each VM runs under its own user LaunchAgent, so VMs outlive the menubar app and can start at
/// login (`RunAtLoad`). The job runs `Proxmacs cli run-vm <name>` (see VMRunner), which owns the
/// serial console and supervises `tart run`.
enum LaunchAgent {
    static func label(_ vm: String) -> String { "dev.proxmacs.vm.\(vm)" }
    static func plistURL(_ vm: String) -> URL { Paths.launchAgents.appending(path: "\(label(vm)).plist") }

    private static var domain: String { "gui/\(getuid())" }
    private static let launchctl = "/bin/launchctl"

    /// Arguments for `tart` (without the executable) as run by VMRunner.
    static func tartRunArguments(meta: VMMeta, serialPath: String) -> [String] {
        // No --vnc-experimental: VZVNCServer asserts/crashes tart on client connect (macOS 27).
        // Browser display uses the guest's Screen Sharing (VNC) on <vm-ip>:5900 instead.
        var args = ["run", meta.name, "--no-graphics", "--serial-path", serialPath]
        // Extra disks come before the seed so they keep their names (/dev/vdb, …) whether or not there is one.
        for disk in meta.disks {
            args += ["--disk", Paths.tartVMDir(meta.name).appending(path: disk.file).path]
        }
        // VMs recreated from a backup have no seed: cloud-init already ran on their disk.
        if FileManager.default.fileExists(atPath: Paths.seedISO(meta.name).path) {
            args += ["--disk", "\(Paths.seedISO(meta.name).path):ro"]
        }
        if case .bridged(let iface) = meta.network {
            args.append("--net-bridged=\(iface)")
        }
        // Named shares all use Tart's default tag, so the guest mounts one virtiofs at /mnt/shared and
        // sees each share as a directory in it.
        for share in meta.shares {
            args += ["--dir", "\(share.name):\(share.path)\(share.readOnly ? ":ro" : "")"]
        }
        if meta.nested { args.append("--nested") }
        return args
    }

    /// Written by `start`, so the runner can tell a start from the UI from a start at login.
    static func manualStartMarker(_ vm: String) -> URL { Paths.vmDir(vm).appending(path: "manual-start") }

    /// This binary (menubar app or CLI build), which provides `cli run-vm`.
    static var selfExecutable: String {
        Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
    }

    static func write(tart: Tart, meta: VMMeta) throws {
        var env = [
            "HOME": Paths.home.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "NSUnbufferedIO": "YES",
        ]
        for key in ["TART_HOME", "PROXMACS_SUPPORT_DIR"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }

        let plist: [String: Any] = [
            "Label": label(meta.name),
            "ProgramArguments": [selfExecutable, "cli", "run-vm", meta.name],
            "RunAtLoad": meta.autostart,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "EnvironmentVariables": env,
            "StandardOutPath": Paths.runLog(meta.name).path,
            "StandardErrorPath": Paths.runLog(meta.name).path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL(meta.name), options: .atomic)
    }

    static func isLoaded(_ vm: String) async -> Bool {
        (try? await Shell.run(launchctl, ["print", "\(domain)/\(label(vm))"]))?.succeeded ?? false
    }

    /// (Re)loads the job from its plist and starts it. Call only while the VM is stopped.
    static func start(_ vm: String) async throws {
        try? Data().write(to: Paths.runLog(vm))
        try? Data().write(to: manualStartMarker(vm))
        // Reload so plist edits (network, autostart) take effect.
        await unload(vm)
        var lastError: Error?
        for _ in 0..<5 {
            do {
                try await Shell.check(launchctl, ["bootstrap", domain, plistURL(vm).path])
                lastError = nil
                break
            } catch {
                // bootout completes asynchronously; bootstrap fails with EIO until it has.
                lastError = error
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        if let lastError { throw lastError }
        try await Shell.check(launchctl, ["kickstart", "\(domain)/\(label(vm))"])
    }

    /// Unloads the job, killing `tart run` if it is still alive.
    static func unload(_ vm: String) async {
        _ = try? await Shell.run(launchctl, ["bootout", "\(domain)/\(label(vm))"])
    }

    static func remove(_ vm: String) async {
        await unload(vm)
        try? FileManager.default.removeItem(at: plistURL(vm))
    }
}
