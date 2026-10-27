import AppKit
import Foundation
import Observation

struct VMItem: Identifiable, Hashable {
    var meta: VMMeta
    /// Tart state ("running", "stopped", "suspended"), "missing" if Tart doesn't know the VM, or
    /// "offline" while VM storage is unavailable (drive disconnected).
    var state: String
    var ip: String?
    var cpus: Int?
    var memoryMB: Int?
    var diskGB: Int?

    var id: String { meta.name }
    var name: String { meta.name }
    var isRunning: Bool { state == "running" }
}

enum ImageSource: Hashable {
    case catalog(CatalogImage)
    /// A .qcow2 or .raw file, imported into the image cache.
    case local(URL)

    static var `default`: ImageSource { .catalog(ImageCatalog.find(ImageCatalog.defaultID)!) }

    /// A catalog id, or the name of an image already imported into the cache.
    static func named(_ id: String) -> ImageSource? {
        if let image = ImageCatalog.find(id) { return .catalog(image) }
        return ImageStore.imported().first { $0.lastPathComponent == id }.map { .local($0) }
    }

    var label: String {
        switch self {
        case .catalog(let image): image.name
        case .local(let url): url.lastPathComponent
        }
    }
}

struct NewVMRequest {
    var name: String
    var cpus: Int
    var memoryMB: Int
    var diskGB: Int
    var network: NetworkMode
    var image: ImageSource
    var password: String
    var autostart: Bool
    var startNow: Bool
    var user = "debian"
    /// nil = the host user's ~/.ssh/*.pub keys.
    var sshKeys: [String]? = nil
    var guestNetwork = GuestNetwork()

    var cloudInit: CloudInitConfig {
        CloudInitConfig(user: user, sshKeys: sshKeys ?? CloudInitSeed.sshPublicKeys(), network: guestNetwork)
    }
}

/// Hardware edits; nil fields stay unchanged. Applied with `tart set`, so the VM must be stopped.
struct HardwareChange {
    var cpus: Int?
    var memoryMB: Int?
    var diskGB: Int?
    var network: NetworkMode?
    var nested: Bool?
}

enum PasswordChange: Equatable {
    case keep
    case set(String)
    case remove
}

struct ProxmacsError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Proxmox-style task log entry: every long-running action is recorded here.
struct TaskRecord: Identifiable, Hashable, Codable {
    enum Status: String, Codable { case running, ok, error }

    var id: String
    var vm: String?
    var title: String
    var status: Status = .running
    var message: String?
    var progress: Double?
    var started = Date()
    var finished: Date?
}

@MainActor
@Observable
final class AppState {
    private(set) var tart: Tart?
    private(set) var tartVersion: String?
    private(set) var vms: [VMItem] = []
    /// VM name → what is currently happening to it.
    private(set) var activity: [String: String] = [:]
    /// Newest first, capped.
    private(set) var tasks: [TaskRecord] = []
    private(set) var memory: HostMemory?
    private(set) var vmStorageOnline = true
    private(set) var backupStorageOnline = true
    /// Set while VM storage or backups are being moved; other actions wait.
    private(set) var storageBusy: StorageKind?
    var status: String? {
        didSet { if let status { onStatus?(status) } }
    }
    var lastError: String?
    /// Lets the CLI echo progress messages.
    var onStatus: ((String) -> Void)?

    let metrics = VMMetrics()
    /// Share of host CPU in use over the last metrics interval.
    private(set) var hostCPU: Double?
    /// Backup jobs currently running.
    private(set) var runningJobs: Set<String> = []

    private var ips: [String: String] = [:]
    private var guestCache: [String: (info: GuestInfo, time: Date)] = [:]

    init(autoRefresh: Bool = true) {
        Paths.ensure()
        JobStore.migrate()
        if autoRefresh {
            Task { await loop() }
            Task { await sampleLoop() }
        }
    }

    private func loop() async {
        while true {
            await refresh()
            await runScheduledJobs()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Separate from `loop`, whose rounds take as long as Tart does.
    private func sampleLoop() async {
        while true {
            try? await Task.sleep(for: VMMetrics.untilNextSample)
            guard let tart, vmStorageOnline else { continue }
            hostCPU = HostStats.cpuUsage() ?? hostCPU
            await metrics.sample(running: vms.filter(\.isRunning), tart: tart)
        }
    }

    func refresh() async {
        memory = HostStats.memory()
        if tart == nil {
            tart = Tart.locate()
            tartVersion = await tart?.version()
        }
        vmStorageOnline = Storage.isAvailable(.vms)
        backupStorageOnline = Storage.isAvailable(.backups)
        guard let tart else { vms = []; return }

        let online = vmStorageOnline && storageBusy != .vms
        let states = online ? Dictionary(((try? await tart.list()) ?? []).map { ($0.name, $0.state) }, uniquingKeysWith: { a, _ in a }) : [:]
        vms = VMMeta.allNames().compactMap(VMMeta.load).map { meta in
            let state = online ? states[meta.name] ?? "missing" : "offline"
            var item = VMItem(meta: meta, state: state, ip: state == "running" ? ips[meta.name] : nil)
            if online { Self.readTartConfig(into: &item) }
            return item
        }

        // A stopped VM's address is no longer its own: its next boot may get another one.
        for item in vms where !item.isRunning { ips[item.name] = nil }
        for item in vms where item.isRunning {
            let ip = await resolveIP(item, tart: tart)
            ips[item.name] = ip
            if let index = vms.firstIndex(where: { $0.name == item.name }) { vms[index].ip = ip }
        }
    }

    private static func readTartConfig(into item: inout VMItem) {
        let dir = Paths.tartVMDir(item.name)
        if let data = try? Data(contentsOf: dir.appending(path: "config.json")),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            item.cpus = (config["cpuCount"] as? NSNumber)?.intValue
            item.memoryMB = (config["memorySize"] as? NSNumber).map { Int($0.int64Value / 1024 / 1024) }
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: dir.appending(path: "disk.img").path))?[.size] as? NSNumber {
            item.diskGB = Int(size.int64Value / 1_000_000_000)
        }
    }

    private func resolveIP(_ item: VMItem, tart: Tart) async -> String? {
        // The guest agent knows the truth in every mode; until it's installed (first boot), fall back
        // to DHCP leases (NAT) or the host ARP table (bridged).
        if let ip = await tart.ip(item.name, resolver: .agent) { return ip }
        switch item.meta.network {
        case .nat: return await tart.ip(item.name, resolver: .dhcp)
        case .bridged: return await tart.ip(item.name, resolver: .arp)
        }
    }

    func isRunning(_ vm: String) -> Bool { item(vm)?.isRunning == true }

    /// The guest IP for the web Display tab: the cached one, or a fresh mode-aware lookup.
    /// `refresh` fills the same cache on its 5-second round; asking here avoids the tab
    /// re-resolving with a fixed resolver order and ignoring the network mode. Nil unless
    /// the VM runs: a stopped VM's last address may belong to another machine by now, and
    /// the Display tab would send it the saved sign-in.
    func ip(_ vm: String) async -> String? {
        guard let tart, let item = item(vm), item.isRunning else { return nil }
        if let cached = ips[vm] { return cached }
        let ip = await resolveIP(item, tart: tart)
        ips[vm] = ip
        return ip
    }

    // MARK: - Tasks

    /// Handle passed to task bodies for progress/message updates (callable from any thread).
    struct TaskHandle: Sendable {
        let id: String
        let update: @Sendable (Double?, String?) -> Void

        func progress(_ fraction: Double) { update(fraction, nil) }
        func message(_ text: String) { update(nil, text) }
    }

    /// Like `perform`, but rethrows the task's error to the caller.
    func performThrowing(_ vm: String?, _ title: String, taskID: String? = nil, _ work: (TaskHandle) async throws -> String?) async throws {
        var failure: Error?
        await perform(vm, title, taskID: taskID) { task in
            do {
                return try await work(task)
            } catch {
                failure = error
                throw error
            }
        }
        if let failure { throw failure }
    }

    /// Runs `work` as a recorded task. Returns false (and records the error) on failure.
    @discardableResult
    func perform(_ vm: String?, _ title: String, taskID: String? = nil, _ work: (TaskHandle) async throws -> String?) async -> Bool {
        let id = taskID ?? UUID().uuidString.lowercased()
        tasks.insert(TaskRecord(id: id, vm: vm, title: title), at: 0)
        if tasks.count > 200 { tasks.removeLast(tasks.count - 200) }
        if let vm { activity[vm] = title }

        let handle = TaskHandle(id: id) { [weak self] progress, message in
            Task { @MainActor in self?.updateTask(id, progress: progress, message: message) }
        }
        var succeeded = true
        do {
            let message = try await work(handle)
            finishTask(id, status: .ok, message: message)
            if let message { status = message }
        } catch {
            succeeded = false
            finishTask(id, status: .error, message: error.localizedDescription)
            lastError = "\(vm.map { "\($0): " } ?? "")\(error.localizedDescription)"
        }
        if let vm { activity[vm] = nil }
        await refresh()
        return succeeded
    }

    private func updateTask(_ id: String, progress: Double?, message: String?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].status == .running else { return }
        if let progress { tasks[index].progress = progress }
        if let message {
            tasks[index].message = message
            status = message
        }
    }

    private func finishTask(_ id: String, status: TaskRecord.Status, message: String?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = status
        tasks[index].finished = Date()
        if status == .ok { tasks[index].progress = 1 }
        if let message { tasks[index].message = message }
    }

    private func requireTart() throws -> Tart {
        guard let tart else { throw ProxmacsError("Tart is not installed (brew install openai/tools/tart)") }
        if let busy = storageBusy { throw ProxmacsError("\(busy.label) is being moved; try again when that has finished") }
        try Storage.require(.vms)
        return tart
    }

    private func item(_ vm: String) -> VMItem? { vms.first { $0.name == vm } }

    // MARK: - VM lifecycle

    func validateNewVM(_ name: String) throws {
        guard name.range(of: #"^[a-z0-9][a-z0-9-]{0,62}$"#, options: .regularExpression) != nil else {
            throw ProxmacsError("Name must be lowercase letters, digits and dashes")
        }
        try Storage.require(.vms)
        if VMMeta.load(name) != nil || FileManager.default.fileExists(atPath: Paths.tartVMDir(name).path) {
            throw ProxmacsError("A VM named \(name) already exists")
        }
    }

    func create(_ request: NewVMRequest, taskID: String? = nil) async throws {
        let name = request.name
        try validateNewVM(name)
        try request.cloudInit.validate()
        try await performThrowing(name, "Create VM", taskID: taskID) { task in
            try await self.createVM(request, task: task)
            return "Created \(name)"
        }
    }

    private func createVM(_ request: NewVMRequest, task: TaskHandle) async throws {
        let tart = try requireTart()
        let name = request.name
        let report: ImageReport = { message, fraction in
            task.message(message)
            if let fraction { task.progress(fraction) }
        }

        let base: URL = switch request.image {
        case .catalog(let image): try await ImageStore.base(image, report: report)
        case .local(let url): try await ImageStore.importLocal(url, report: report)
        }
        let neededGB = Int((FileCopy.size(of: base) + 999_999_999) / 1_000_000_000)
        guard request.diskGB >= neededGB else {
            throw ProxmacsError("\(request.image.label) needs a disk of at least \(neededGB) GB")
        }
        let agent = try await ImageStore.agentPackages(report: report)

        task.message("Creating VM \(name)…")
        try await tart.createLinux(name, diskSizeGB: request.diskGB)
        do {
            try await tart.set(name, cpu: request.cpus, memoryMB: request.memoryMB)
            task.message("Copying base image…")
            try await BackupManager.setDisk(name, from: base) { task.progress($0) }
            try await tart.set(name, diskSizeGB: request.diskGB)

            var config = request.cloudInit
            if !request.password.isEmpty {
                let password = request.password
                config.passwordHash = await Task.detached { SHA512Crypt.hash(password) }.value
            }
            var meta = VMMeta(name: name, network: request.network, autostart: request.autostart)
            meta.cloudInit = config
            meta.image = request.image.label
            try meta.save()
            task.message("Building cloud-init seed…")
            try await CloudInitSeed.build(name: name, config: config, agentPackages: agent)
            try LaunchAgent.write(tart: tart, meta: meta)
        } catch {
            // Roll back so a half-created VM doesn't linger.
            try? await tart.delete(name)
            try? FileManager.default.removeItem(at: Paths.vmDir(name))
            try? FileManager.default.removeItem(at: LaunchAgent.plistURL(name))
            throw error
        }

        if request.startNow {
            task.message("Starting \(name)…")
            try await LaunchAgent.start(name)
        }
    }

    // MARK: - Images

    /// Downloads a catalog image into the cache, so creating VMs from it doesn't wait for the download.
    func downloadImage(_ image: CatalogImage, taskID: String? = nil) async throws {
        try await performThrowing(nil, "Download \(image.name)", taskID: taskID) { task in
            let raw = try await ImageStore.base(image) { message, fraction in
                task.message(message)
                if let fraction { task.progress(fraction) }
            }
            let size = ByteCountFormatter.string(fromByteCount: FileCopy.allocatedSize(of: raw), countStyle: .memory)
            return "\(image.name) is ready (\(size) on disk)"
        }
    }

    func deleteImage(_ id: String) throws {
        try ImageStore.delete(id)
        status = "Deleted image \(ImageCatalog.find(id)?.name ?? id)"
    }

    func start(_ vm: String, taskID: String? = nil) async {
        await perform(vm, "Start", taskID: taskID) { _ in
            let tart = try requireTart()
            guard let meta = VMMeta.load(vm) else { throw ProxmacsError("missing metadata") }
            if meta.template { throw ProxmacsError("\(vm) is a template: clone it to get a VM you can start") }
            try LaunchAgent.write(tart: tart, meta: meta)  // pick up any metadata changes
            try await LaunchAgent.start(vm)
            return nil
        }
    }

    /// Shuts the guest down (forced off after 30 s), or with `force` turns it off at once.
    func stop(_ vm: String, force: Bool = false, taskID: String? = nil) async {
        await perform(vm, force ? "Stop" : "Shutdown", taskID: taskID) { _ in
            try await requireTart().stop(vm, timeout: force ? 0 : 30)
            return nil
        }
    }

    /// Reboots through the guest agent, or by stopping and starting the VM (always, with `force`).
    func reboot(_ vm: String, force: Bool = false, taskID: String? = nil) async {
        await perform(vm, force ? "Reset" : "Reboot", taskID: taskID) { task in
            let tart = try requireTart()
            guard item(vm)?.isRunning == true else { throw ProxmacsError("\(vm) is not running") }
            if !force, (try? await tart.exec(vm, ["systemctl", "reboot"], timeout: 10))?.succeeded == true {
                return "Rebooting \(vm)"
            }
            task.message(force ? "Turning \(vm) off…" : "Guest agent unreachable: shutting \(vm) down…")
            try await tart.stop(vm, timeout: force ? 0 : 30)
            guard let meta = VMMeta.load(vm) else { throw ProxmacsError("missing metadata") }
            try LaunchAgent.write(tart: tart, meta: meta)
            task.message("Starting \(vm)…")
            try await LaunchAgent.start(vm)
            return nil
        }
    }

    func delete(_ vm: String, taskID: String? = nil) async {
        await perform(vm, "Delete", taskID: taskID) { _ in
            let tart = try requireTart()
            if item(vm)?.isRunning == true {
                try? await tart.stop(vm, timeout: 10)
            }
            await LaunchAgent.remove(vm)
            if FileManager.default.fileExists(atPath: Paths.tartVMDir(vm).path) {
                try await tart.delete(vm)
            }
            try FileManager.default.removeItem(at: Paths.vmDir(vm))
            try? VNCCredentials.clear(vm)
            ips[vm] = nil
            guestCache[vm] = nil
            metrics.forget(vm)
            return "Deleted \(vm); backups kept"
        }
    }

    // MARK: - Editing

    func editHardware(_ vm: String, _ change: HardwareChange, taskID: String? = nil) async throws {
        guard let current = item(vm), let meta = VMMeta.load(vm) else { throw ProxmacsError("No VM named \(vm)") }
        let networkChanged = change.network.map { $0 != meta.network } ?? false
        let cpus = change.cpus.flatMap { $0 == current.cpus ? nil : $0 }
        let memoryMB = change.memoryMB.flatMap { $0 == current.memoryMB ? nil : $0 }
        let diskGB = change.diskGB.flatMap { $0 == current.diskGB ? nil : $0 }
        let nested = change.nested.flatMap { $0 == meta.nested ? nil : $0 }
        guard cpus != nil || memoryMB != nil || diskGB != nil || networkChanged || nested != nil else { return }

        guard current.state == "stopped" else { throw ProxmacsError("Shut down \(vm) before changing its hardware") }
        let hostCPUs = ProcessInfo.processInfo.activeProcessorCount
        if let cpus, !(1...hostCPUs).contains(cpus) { throw ProxmacsError("CPUs must be between 1 and \(hostCPUs)") }
        let hostMB = Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)
        if let memoryMB, !(512...hostMB).contains(memoryMB) { throw ProxmacsError("Memory must be between 512 MB and \(hostMB) MB") }
        if let diskGB, let size = current.diskGB, diskGB < size {
            throw ProxmacsError("Disks can only grow (\(vm) has \(size) GB)")
        }
        if let diskGB, diskGB > 16_384 { throw ProxmacsError("Disk size too large") }

        try await performThrowing(vm, "Edit hardware", taskID: taskID) { _ in
            let tart = try requireTart()
            if cpus != nil || memoryMB != nil || diskGB != nil {
                try await tart.set(vm, cpu: cpus, memoryMB: memoryMB, diskSizeGB: diskGB)
            }
            if networkChanged, let network = change.network {
                try updateMeta(vm) { $0.network = network }
            }
            if let nested { try updateMeta(vm) { $0.nested = nested } }
            var changes: [String] = []
            if let cpus { changes.append("\(cpus) CPUs") }
            if let memoryMB { changes.append("\(memoryMB) MB memory") }
            if let diskGB { changes.append("\(diskGB) GB disk (the root filesystem grows on next boot)") }
            if networkChanged, let network = change.network { changes.append(network.label) }
            if let nested { changes.append("nested virtualization \(nested ? "on" : "off")") }
            return "\(vm): " + changes.joined(separator: ", ")
        }
    }

    /// Stores new cloud-init settings and rebuilds the seed; cloud-init applies them on the next start.
    func editCloudInit(_ vm: String, user: String, password: PasswordChange, sshKeys: [String], network: GuestNetwork,
                       taskID: String? = nil) async throws {
        guard let meta = VMMeta.load(vm) else { throw ProxmacsError("No VM named \(vm)") }
        var config = meta.effectiveCloudInit
        config.user = user
        config.sshKeys = sshKeys
        config.network = network
        switch password {
        case .keep:
            break
        case .set(let plain):
            guard !plain.isEmpty else { throw ProxmacsError("Password is empty") }
            config.passwordHash = await Task.detached { SHA512Crypt.hash(plain) }.value
            config.managePassword = true
        case .remove:
            config.passwordHash = nil
            config.managePassword = true
        }
        try config.validate()

        try await performThrowing(vm, "Edit cloud-init", taskID: taskID) { task in
            let agent = try await ImageStore.agentPackages { message, _ in task.message(message) }
            try await CloudInitSeed.build(name: vm, config: config, agentPackages: agent, newIdentity: meta.newIdentity)
            let running = item(vm)?.isRunning ?? false
            try updateMeta(vm) {
                $0.cloudInit = config
                $0.seedPending = running
            }
            return running ? "Cloud-init updated: shut down and start \(vm) to apply" : "Cloud-init updated: applied when \(vm) next starts"
        }
    }

    func updateMeta(_ vm: String, _ change: (inout VMMeta) -> Void) throws {
        guard var meta = VMMeta.load(vm) else { throw ProxmacsError("No VM named \(vm)") }
        change(&meta)
        try meta.save()
        if let tart { try LaunchAgent.write(tart: tart, meta: meta) }
        if let index = vms.firstIndex(where: { $0.name == vm }) { vms[index].meta = meta }
    }

    func setAutostart(_ vm: String, _ enabled: Bool) async {
        do { try updateMeta(vm) { $0.autostart = enabled } } catch { lastError = error.localizedDescription }
    }

    func setBackupPolicy(_ vm: String, _ policy: BackupPolicy) {
        do { try updateMeta(vm) { $0.backup = policy } } catch { lastError = error.localizedDescription }
    }

    // MARK: - Clones and templates

    /// Copies a VM (all disks, NVRAM, settings) under a new name, with a new MAC address. A running source is
    /// cloned like a backup: its root filesystem is frozen for the instant APFS clone. The clone's first boot
    /// regenerates its SSH host keys and machine-id.
    func clone(_ source: String, to name: String, start: Bool, network: GuestNetwork? = nil, taskID: String? = nil) async throws {
        guard let sourceMeta = VMMeta.load(source), FileManager.default.fileExists(atPath: Paths.tartVMDir(source).path) else {
            throw ProxmacsError("No VM named \(source)")
        }
        try validateNewVM(name)
        var config = sourceMeta.effectiveCloudInit
        if let network { config.network = network }
        try config.validate()

        try await performThrowing(name, "Clone \(source)", taskID: taskID) { task in
            let tart = try requireTart()
            let running = item(source)?.isRunning ?? false
            let files = BackupManager.vmFiles + sourceMeta.disks.map(\.file)
            let agent = try await ImageStore.agentPackages { message, _ in task.message(message) }

            task.message("Creating \(name)…")
            try await tart.createLinux(name, diskSizeGB: 1)
            do {
                let stage = try BackupManager.stagingDir()
                defer { BackupManager.removeStaging(stage) }
                task.message(running ? "Cloning the disks of running \(source)…" : "Cloning the disks of \(source)…")
                let frozen = try await BackupManager.snapshot(source, files: files, into: stage, running: running, tart: tart)
                let target = Paths.tartVMDir(name)
                for file in files {
                    let destination = target.appending(path: file)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: stage.appending(path: file), to: destination)
                }
                try await tart.set(name, randomMAC: true)

                var meta = sourceMeta
                meta.name = name
                meta.autostart = false
                meta.template = false
                meta.created = Date()
                meta.seedPending = false
                meta.newIdentity = true
                meta.startOrder = nil
                meta.cloudInit = config
                try meta.save()
                task.message("Building cloud-init seed…")
                try await CloudInitSeed.build(name: name, config: config, agentPackages: agent, newIdentity: true)
                try LaunchAgent.write(tart: tart, meta: meta)
                if running, !frozen { task.message("Cloned without freezing \(source): guest agent unreachable") }
            } catch {
                try? await tart.delete(name)
                try? FileManager.default.removeItem(at: Paths.vmDir(name))
                try? FileManager.default.removeItem(at: LaunchAgent.plistURL(name))
                throw error
            }
            if start {
                task.message("Starting \(name)…")
                try await LaunchAgent.start(name)
            }
            return "Cloned \(source) to \(name)"
        }
    }

    func setTemplate(_ vm: String, _ template: Bool) throws {
        guard let current = item(vm) else { throw ProxmacsError("No VM named \(vm)") }
        if template, current.state != "stopped" { throw ProxmacsError("Shut down \(vm) before converting it to a template") }
        try updateMeta(vm) {
            $0.template = template
            if template { $0.autostart = false }
        }
        status = template ? "\(vm) is now a template" : "\(vm) is a VM again"
    }

    // MARK: - Extra disks and shared folders

    private func requireStopped(_ vm: String, _ what: String) throws {
        guard let current = item(vm) else { throw ProxmacsError("No VM named \(vm)") }
        guard current.state == "stopped" else { throw ProxmacsError("Shut down \(vm) before \(what)") }
    }

    /// Size in GB (as Tart counts them) of a disk image.
    static func diskGB(_ url: URL) -> Int { Int(FileCopy.size(of: url) / 1_000_000_000) }

    func addDisk(_ vm: String, sizeGB: Int) throws -> String {
        try requireStopped(vm, "adding a disk")
        _ = try requireTart()
        guard (1...16_384).contains(sizeGB) else { throw ProxmacsError("Disk size must be between 1 and 16384 GB") }
        guard let meta = VMMeta.load(vm) else { throw ProxmacsError("No VM named \(vm)") }
        let dir = Paths.tartVMDir(vm)
        guard let file = (1...99).map({ "disk\($0).img" }).first(where: { name in
            !meta.disks.contains { $0.file == name } && !FileManager.default.fileExists(atPath: dir.appending(path: name).path)
        }) else { throw ProxmacsError("Too many disks") }
        let url = dir.appending(path: file)
        // A sparse file: it takes no space until the guest writes to it.
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ProxmacsError("Cannot create \(url.path)") }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(sizeGB) * 1_000_000_000)
        try updateMeta(vm) { $0.disks.append(ExtraDisk(file: file)) }
        status = "Added a \(sizeGB) GB disk to \(vm) (\(file))"
        return file
    }

    func resizeDisk(_ vm: String, file: String, sizeGB: Int) throws {
        try requireStopped(vm, "resizing its disks")
        _ = try requireTart()
        guard VMMeta.load(vm)?.disks.contains(where: { $0.file == file }) == true else { throw ProxmacsError("\(vm) has no disk \(file)") }
        let url = Paths.tartVMDir(vm).appending(path: file)
        let current = FileCopy.size(of: url)
        let size = Int64(sizeGB) * 1_000_000_000
        guard sizeGB <= 16_384 else { throw ProxmacsError("Disk size too large") }
        guard size >= current else { throw ProxmacsError("Disks can only grow (\(file) has \(Self.diskGB(url)) GB)") }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }

    func removeDisk(_ vm: String, file: String) throws {
        try requireStopped(vm, "removing a disk")
        _ = try requireTart()
        guard VMMeta.load(vm)?.disks.contains(where: { $0.file == file }) == true, ExtraDisk.isValidFile(file) else {
            throw ProxmacsError("\(vm) has no disk \(file)")
        }
        try updateMeta(vm) { $0.disks.removeAll { $0.file == file } }
        try? FileManager.default.removeItem(at: Paths.tartVMDir(vm).appending(path: file))
        status = "Removed \(file) from \(vm)"
    }

    func setDiskBackup(_ vm: String, file: String, backup: Bool) throws {
        guard VMMeta.load(vm)?.disks.contains(where: { $0.file == file }) == true else { throw ProxmacsError("\(vm) has no disk \(file)") }
        try updateMeta(vm) { meta in
            if let index = meta.disks.firstIndex(where: { $0.file == file }) { meta.disks[index].backup = backup }
        }
    }

    func addShare(_ vm: String, _ share: SharedFolder) async throws {
        try requireStopped(vm, "changing its shared folders")
        guard SharedFolder.isValidName(share.name) else {
            throw ProxmacsError("Share names are letters, digits, dots, dashes and underscores")
        }
        let path = URL(fileURLWithPath: (share.path as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw ProxmacsError("\(share.path) is not a folder on this Mac")
        }
        guard !path.contains(":") else { throw ProxmacsError("Folder paths can't contain a colon") }
        guard let meta = VMMeta.load(vm), !meta.shares.contains(where: { $0.name == share.name }) else {
            throw ProxmacsError("\(vm) already has a share named \(share.name)")
        }
        try updateMeta(vm) { $0.shares.append(SharedFolder(name: share.name, path: path, readOnly: share.readOnly)) }
        try await ensureShareMount(vm)
    }

    func removeShare(_ vm: String, name: String) throws {
        try requireStopped(vm, "changing its shared folders")
        try updateMeta(vm) { $0.shares.removeAll { $0.name == name } }
    }

    /// Seeds built before shared folders existed lack the unit that mounts them: rebuild once.
    private func ensureShareMount(_ vm: String) async throws {
        let version = (try? String(contentsOf: CloudInitSeed.versionFile(vm), encoding: .utf8)).flatMap { Int($0) } ?? 1
        guard version < 2, let meta = VMMeta.load(vm), FileManager.default.fileExists(atPath: Paths.seedISO(vm).path) else { return }
        let agent = try await ImageStore.agentPackages { _, _ in }
        try await CloudInitSeed.build(name: vm, config: meta.effectiveCloudInit, agentPackages: agent, newIdentity: meta.newIdentity)
    }

    // MARK: - Guest

    /// Guest OS, interfaces and filesystems from the agent; cached for 30 s.
    func guestInfo(_ vm: String, refresh: Bool = false) async throws -> GuestInfo {
        if !refresh, let cached = guestCache[vm], Date().timeIntervalSince(cached.time) < 30 { return cached.info }
        let tart = try requireTart()
        guard item(vm)?.isRunning == true else { throw ProxmacsError("\(vm) is not running") }
        let info = try await GuestInfo.fetch(vm, tart: tart)
        guestCache[vm] = (info, Date())
        return info
    }

    // MARK: - Local backups

    /// Backs up to local backups, or with `targetID` straight to that offsite target. Returns whether the
    /// backup succeeded (offsite pushes after a local backup are separate tasks).
    @discardableResult
    func backup(_ vm: String, to targetID: String? = nil, taskID: String? = nil) async -> Bool {
        if let targetID { return await backupOffsite(vm, targetID: targetID, taskID: taskID) }
        let ok = await perform(vm, "Backup", taskID: taskID) { task in
            let tart = try requireTart()
            if storageBusy == .backups { throw ProxmacsError("Backups are being moved; try again when that has finished") }
            let running = item(vm)?.isRunning ?? false
            let policy = VMMeta.load(vm)?.backup ?? BackupPolicy()
            let info = try await BackupManager.backup(vm, running: running, tart: tart, policy: policy) { task.progress($0) }
            return info.record.consistent ? "Backup of \(vm) done" : "Backup of \(vm) done (crash-consistent: guest agent unreachable)"
        }
        guard ok, let meta = VMMeta.load(vm), meta.offsite.auto, let latest = BackupManager.list(vm).first else { return ok }
        for target in meta.offsite.targets {
            await push(vm, backup: latest, targetID: target)
        }
        return ok
    }

    private func backupOffsite(_ vm: String, targetID: String, taskID: String?) async -> Bool {
        guard let target = TargetStore.target(targetID) else {
            lastError = "Unknown backup target \(targetID)"
            return false
        }
        return await perform(vm, "Backup to \(target.name)", taskID: taskID) { task in
            let tart = try requireTart()
            let backend = try target.backend()
            let running = item(vm)?.isRunning ?? false
            task.message("Backing up \(vm) to \(target.name)…")
            let record = try await BackupManager.backup(vm, running: running, tart: tart, to: backend) { task.progress($0) }
            let kind = record.consistent ? "" : " (crash-consistent: guest agent unreachable)"
            do {
                try await backend.prune(vm: vm, keep: target.keep)
            } catch {
                return "Backed up \(vm) to \(target.name)\(kind); prune failed: \(error.localizedDescription)"
            }
            return "Backed up \(vm) to \(target.name)\(kind)"
        }
    }

    // MARK: - Backup jobs

    private func runScheduledJobs() async {
        let now = Date()
        for job in JobStore.load() where job.isDue(now) && !runningJobs.contains(job.id) {
            await runJob(job.id)
        }
    }

    /// Backs up every VM the job selects, one after another, then notifies as configured.
    func runJob(_ id: String, taskID: String? = nil) async {
        guard let job = JobStore.job(id), !runningJobs.contains(id) else { return }
        runningJobs.insert(id)
        defer { runningJobs.remove(id) }
        JobStore.update(id) { $0.lastRun = Date() }
        var failed: [String] = []
        var done: [String] = []
        var skipped: [String] = []
        await perform(nil, job.title, taskID: taskID) { task in
            let members = vms.filter { job.selects($0.name) }
            if members.isEmpty { throw ProxmacsError("The job selects no VMs") }
            if let target = job.target, TargetStore.target(target) == nil {
                throw ProxmacsError("The job's backup target no longer exists")
            }
            for (index, vm) in members.enumerated() {
                task.message("Backing up \(vm.name) (\(index + 1) of \(members.count))…")
                if vm.state == "missing" || vm.state == "offline" {
                    skipped.append(vm.name)
                } else if await backup(vm.name, to: job.target) {
                    done.append(vm.name)
                } else {
                    failed.append(vm.name)
                }
                task.progress(Double(index + 1) / Double(members.count))
            }
            let summary = Self.jobSummary(done: done, failed: failed, skipped: skipped)
            if !failed.isEmpty { throw ProxmacsError(summary) }
            return summary
        }
        let ok = failed.isEmpty && !done.isEmpty
        let summary = done.isEmpty && failed.isEmpty && skipped.isEmpty ? "The job selects no VMs" : Self.jobSummary(done: done, failed: failed, skipped: skipped)
        JobStore.update(id) {
            $0.lastOK = ok
            $0.lastMessage = summary
        }
        if job.notify == .always || (job.notify == .failure && !ok) {
            let host = ProcessInfo.processInfo.hostName
            var lines = [summary]
            for name in failed {
                if let error = tasks.first(where: { $0.vm == name && $0.title.hasPrefix("Backup") })?.message { lines.append("\(name): \(error)") }
            }
            let errors = await Notifier.broadcast(title: "\(ok ? "✅" : "❌") \(job.title) on \(host)", message: lines.joined(separator: "\n"),
                                                  failed: !ok)
            if !errors.isEmpty { lastError = "Notification failed: " + errors.joined(separator: "; ") }
        }
    }

    private static func jobSummary(done: [String], failed: [String], skipped: [String]) -> String {
        var parts: [String] = []
        if !done.isEmpty { parts.append("backed up \(done.joined(separator: ", "))") }
        if !failed.isEmpty { parts.append("failed: \(failed.joined(separator: ", "))") }
        if !skipped.isEmpty { parts.append("skipped (missing or offline): \(skipped.joined(separator: ", "))") }
        return parts.joined(separator: "; ").prefix(1).uppercased() + parts.joined(separator: "; ").dropFirst()
    }

    func restore(_ vm: String, _ backup: BackupInfo, taskID: String? = nil) async {
        await perform(vm, "Restore", taskID: taskID) { task in
            let tart = try requireTart()
            try Storage.require(.backups)
            if VMMeta.load(vm) == nil || !FileManager.default.fileExists(atPath: Paths.tartVMDir(vm).path) {
                try await recreate(vm, from: backup, tart: tart, task: task)
                return "Recreated \(vm) from backup of \(backup.record.date.formatted())"
            }
            if item(vm)?.isRunning == true {
                throw ProxmacsError("Stop the VM before restoring")
            }
            let extra = try await BackupManager.restore(vm, from: backup) { task.progress($0) }
            try updateMeta(vm) { meta in
                for file in extra where !meta.disks.contains(where: { $0.file == file }) { meta.disks.append(ExtraDisk(file: file)) }
            }
            return "Restored \(vm) from \(backup.record.date.formatted())"
        }
    }

    /// Disaster recovery: builds a VM that no longer exists from a (possibly pulled) backup.
    private func recreate(_ vm: String, from backup: BackupInfo, tart: Tart, task: TaskHandle) async throws {
        task.message("Recreating \(vm) from backup…")
        let disk = backup.url.appending(path: BackupFiles.disk)
        let size = ((try? FileManager.default.attributesOfItem(atPath: disk.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let diskGB = max(Int((size + 999_999_999) / 1_000_000_000), 1)

        if !FileManager.default.fileExists(atPath: Paths.tartVMDir(vm).path) {
            try await tart.createLinux(vm, diskSizeGB: diskGB)
        }
        let tartDir = Paths.tartVMDir(vm)
        // Tart's config carries the MAC address: keeping it preserves DHCP reservations on the LAN.
        for file in ["config.json", "nvram.bin"] {
            let source = backup.url.appending(path: file)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try? FileManager.default.removeItem(at: tartDir.appending(path: file))
            try FileManager.default.copyItem(at: source, to: tartDir.appending(path: file))
        }
        try await BackupManager.setDisk(vm, from: disk) { task.progress($0) }
        let extra = BackupManager.extraDisks(in: backup.url)
        for file in extra {
            try await BackupManager.setDisk(vm, file: file, from: backup.url.appending(path: file), create: true)
        }

        var meta = (try? JSONDecoder.proxmacs.decode(VMMeta.self, from: Data(contentsOf: backup.url.appending(path: "meta.json"))))
            ?? VMMeta(name: vm, network: .nat, autostart: false)
        meta.name = vm
        meta.autostart = false
        // Disks not in the backup (excluded from backups) start out detached.
        meta.disks = meta.disks.filter { extra.contains($0.file) }
        for file in extra where !meta.disks.contains(where: { $0.file == file }) { meta.disks.append(ExtraDisk(file: file)) }
        try meta.save()
        try LaunchAgent.write(tart: tart, meta: meta)
    }

    func deleteBackup(_ backup: BackupInfo) throws {
        try BackupManager.delete(backup)
    }

    // MARK: - Offsite

    var targets: [OffsiteTarget] { TargetStore.load() }

    @discardableResult
    func push(_ vm: String, backup: BackupInfo, targetID: String, taskID: String? = nil) async -> Bool {
        guard let target = TargetStore.target(targetID) else {
            lastError = "Unknown offsite target \(targetID)"
            return false
        }
        return await perform(vm, "Push to \(target.name)", taskID: taskID) { task in
            try Storage.require(.backups)
            let backend = try target.backend()
            task.message("Uploading \(vm) to \(target.name)…")
            try await backend.push(vm: vm, backupDir: backup.url, record: backup.record) { task.progress($0) }
            do {
                try await backend.prune(vm: vm, keep: target.keep)
            } catch {
                return "Pushed \(vm) to \(target.name) (prune failed: \(error.localizedDescription))"
            }
            return "Pushed \(vm) to \(target.name)"
        }
    }

    func remoteSnapshots(targetID: String, vm: String) async throws -> [RemoteSnapshot] {
        guard let target = TargetStore.target(targetID) else { throw ProxmacsError("Unknown offsite target \(targetID)") }
        return try await target.backend().snapshots(vm: vm)
    }

    /// Copies a remote snapshot into the local backups of `vm`; recreates the VM if it doesn't exist.
    func pull(_ vm: String, snapshotID: String, targetID: String, taskID: String? = nil) async {
        guard let target = TargetStore.target(targetID) else {
            lastError = "Unknown offsite target \(targetID)"
            return
        }
        var pulled: BackupInfo?
        let ok = await perform(vm, "Pull from \(target.name)", taskID: taskID) { task in
            try Storage.require(.backups)
            if storageBusy == .backups { throw ProxmacsError("Backups are being moved; try again when that has finished") }
            let backend = try target.backend()
            let snapshots = try await backend.snapshots(vm: vm)
            guard let snapshot = snapshots.first(where: { $0.id == snapshotID }) else {
                throw ProxmacsError("Snapshot \(snapshotID) of \(vm) not found on \(target.name)")
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
            let dir = Paths.backupsDir(vm).appending(path: "\(formatter.string(from: snapshot.time))-\(target.name)", directoryHint: .isDirectory)
            let partial = dir.appendingPathExtension("partial")
            try? FileManager.default.removeItem(at: partial)
            task.message("Downloading \(vm) from \(target.name)…")
            try await backend.pull(snapshot, into: partial) { task.progress($0) }
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.moveItem(at: partial, to: dir)
            pulled = BackupManager.list(vm).first { $0.url.lastPathComponent == dir.lastPathComponent }
            return "Pulled \(vm) snapshot into local backups"
        }
        if ok, let pulled, VMMeta.load(vm) == nil {
            await restore(vm, pulled)
        }
    }

    /// Reads a remote snapshot back from the target and checks every chunk.
    func verify(_ vm: String, snapshotID: String, targetID: String, taskID: String? = nil) async {
        guard let target = TargetStore.target(targetID) else {
            lastError = "Unknown offsite target \(targetID)"
            return
        }
        await perform(vm, "Verify on \(target.name)", taskID: taskID) { task in
            let backend = try target.backend()
            guard let snapshot = try await backend.snapshots(vm: vm).first(where: { $0.id == snapshotID }) else {
                throw ProxmacsError("Snapshot \(snapshotID) of \(vm) not found on \(target.name)")
            }
            task.message("Reading \(vm) snapshot back from \(target.name)…")
            let summary = try await backend.verify(snapshot) { task.progress($0) }
            return "\(vm) snapshot of \(snapshot.time.formatted()) on \(target.name): \(summary)"
        }
    }

    func addTarget(_ target: OffsiteTarget, secret: String?) throws {
        try TargetStore.add(target, secret: secret)
    }

    func removeTarget(_ id: String) throws {
        if let job = JobStore.load().first(where: { $0.target == id }) {
            throw ProxmacsError("Backup job “\(job.title)” backs up to this target: change or delete it first")
        }
        try TargetStore.remove(id)
        for vm in VMMeta.allNames() {
            try? updateMeta(vm) { $0.offsite.targets.removeAll { $0 == id } }
        }
    }

    func testTarget(_ id: String) async -> (ok: Bool, message: String) {
        guard let target = TargetStore.target(id) else { return (false, "Unknown target") }
        do {
            return (true, try await target.backend().test())
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Storage

    struct StoragePlan {
        var kind: StorageKind
        var old: URL
        var new: URL
        var custom: Bool
        var moves: [(from: URL, to: URL)]
        var crossVolume: Bool
        var oldAvailable: Bool
        /// Backups already present at the new location (left where they are).
        var skipped: Int
    }

    /// Checks a move of VM storage or local backups to `path` (nil = back to the default on the
    /// internal disk). Data reachable at the old location moves along; a new location that already
    /// holds Proxmacs data of the same kind (a reconnected drive) is adopted as is.
    func planStorageChange(_ kind: StorageKind, to path: String?) async throws -> StoragePlan {
        if kind == .vms && Storage.tartHomeOverridden { throw ProxmacsError("VM storage is set by the TART_HOME environment variable") }
        if let busy = storageBusy { throw ProxmacsError("\(busy.label) is already being moved") }
        let old = Storage.canonical(Storage.url(kind))
        let requested = path.map(Storage.canonical(path:)) ?? Storage.canonical(kind == .vms ? Paths.defaultTartHome : Paths.defaultBackups)
        guard requested.path != old.path else { throw ProxmacsError("\(kind.label) is already at \(old.path)") }
        let new = try path.map { try Storage.validate($0, for: kind) } ?? requested

        await refresh()
        guard activity.isEmpty else { throw ProxmacsError("Wait for running tasks to finish first") }
        if kind == .vms, let running = vms.first(where: \.isRunning) {
            throw ProxmacsError("Shut down all VMs first (\(running.name) is running)")
        }

        let oldAvailable = Storage.isAvailable(kind)
        var moves: [(from: URL, to: URL)] = []
        var skipped = 0
        if oldAvailable {
            let fm = FileManager.default
            switch kind {
            case .vms:
                for name in VMMeta.allNames() {
                    let from = old.appending(path: "vms/\(name)", directoryHint: .isDirectory)
                    let to = new.appending(path: "vms/\(name)", directoryHint: .isDirectory)
                    guard fm.fileExists(atPath: from.path) else { continue }
                    if fm.fileExists(atPath: to.path) {
                        throw ProxmacsError("\(new.path) already holds a VM named \(name); remove one of them first")
                    }
                    moves.append((from, to))
                }
            case .backups:
                let vmDirs = (try? fm.contentsOfDirectory(atPath: old.path)) ?? []
                for vm in vmDirs.sorted() where vm.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil {
                    for entry in ((try? fm.contentsOfDirectory(atPath: old.appending(path: vm).path)) ?? []).sorted() {
                        let from = old.appending(path: "\(vm)/\(entry)", directoryHint: .isDirectory)
                        if entry.hasSuffix(".partial") { continue }
                        let to = new.appending(path: "\(vm)/\(entry)", directoryHint: .isDirectory)
                        if fm.fileExists(atPath: to.path) { skipped += 1; continue }
                        moves.append((from, to))
                    }
                }
            }
        }
        let crossVolume = !FileCopy.sameVolume(old, new)
        if crossVolume, !moves.isEmpty, let volume = Storage.volume(containing: new) {
            let needed = moves.reduce(Int64(0)) { $0 + FileCopy.allocatedSize(of: $1.from) }
            if needed > volume.freeBytes {
                throw ProxmacsError("Not enough space on \(volume.name): \(Self.bytes(needed)) needed, \(Self.bytes(volume.freeBytes)) free")
            }
        }
        return StoragePlan(kind: kind, old: old, new: new, custom: path != nil, moves: moves, crossVolume: crossVolume,
                           oldAvailable: oldAvailable, skipped: skipped)
    }

    func changeStorage(_ plan: StoragePlan, taskID: String? = nil) async throws {
        if let busy = storageBusy { throw ProxmacsError("\(busy.label) is already being moved") }
        storageBusy = plan.kind
        do {
            try await moveStorage(plan, taskID: taskID)
        } catch {
            storageBusy = nil
            await refresh()
            throw error
        }
        storageBusy = nil
        await refresh()
    }

    private func moveStorage(_ plan: StoragePlan, taskID: String?) async throws {
        let (kind, old, new, custom, moves) = (plan.kind, plan.old, plan.new, plan.custom, plan.moves)
        let (crossVolume, oldAvailable, skipped) = (plan.crossVolume, plan.oldAvailable, plan.skipped)
        try await performThrowing(nil, "Move \(kind.noun)", taskID: taskID) { task in
            if custom { try Storage.prepare(new, for: kind) } else {
                try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
            }
            task.message("Moving \(moves.count) \(kind == .vms ? "VM" : "backup")\(moves.count == 1 ? "" : "s") to \(new.path)…")
            try await Task.detached(priority: .userInitiated) {
                try Self.transfer(moves, crossVolume: crossVolume, staging: new.appending(path: ".proxmacs-moving", directoryHint: .isDirectory)) {
                    task.progress($0)
                }
            }.value

            var settings = Storage.settings
            settings[kind] = custom ? new.path : nil
            try Storage.save(settings)
            if kind == .vms {
                try? FileManager.default.removeItem(at: old.appending(path: ".proxmacs-staging"))
            }
            var message = "\(kind.label) is now at \(new.path)"
            if !oldAvailable {
                message += "; the old location was not available, so nothing was moved"
            } else if !moves.isEmpty {
                message += " (moved \(moves.count) \(kind == .vms ? "VM" : "backup")\(moves.count == 1 ? "" : "s"))"
            }
            if skipped > 0 { message += "; \(skipped) backup(s) already present there were left at \(old.path)" }
            return message
        }
    }

    /// Copies everything first (sources untouched, so a failure changes nothing), then renames the
    /// copies into place and deletes the sources. Within one volume it just renames.
    private nonisolated static func transfer(_ moves: [(from: URL, to: URL)], crossVolume: Bool, staging: URL,
                                             progress: @escaping (Double) -> Void) throws {
        let fm = FileManager.default
        if !crossVolume {
            for (index, move) in moves.enumerated() {
                try fm.createDirectory(at: move.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: move.from, to: move.to)
                progress(Double(index + 1) / Double(moves.count))
            }
            return
        }
        let total = Double(max(moves.reduce(Int64(0)) { $0 + FileCopy.size(of: $1.from) }, 1))
        var done: Int64 = 0
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for (index, move) in moves.enumerated() {
            try FileCopy.copyTree(move.from, to: staging.appending(path: String(index))) { bytes in
                done += bytes
                progress(min(Double(done) / total, 0.99))
            }
        }
        for (index, move) in moves.enumerated() {
            try fm.createDirectory(at: move.to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staging.appending(path: String(index)), to: move.to)
        }
        for move in moves {
            try? fm.removeItem(at: move.from)
            // Drop emptied per-VM backup directories.
            let parent = move.from.deletingLastPathComponent()
            if (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true, parent.lastPathComponent != "vms" {
                try? fm.removeItem(at: parent)
            }
        }
        progress(1)
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    // MARK: - Host helpers

    func openConsole(_ vm: String) {
        guard FileManager.default.fileExists(atPath: VMRunner.socketPath(vm).path) else {
            lastError = "\(vm): no console (is the VM running?)"
            return
        }
        let script = Paths.vmDir(vm).appending(path: "console.command")
        let body = """
        #!/bin/sh
        printf '\\033]0;%s console\\007' '\(vm)'
        exec '\(LaunchAgent.selfExecutable)' cli console '\(vm)'

        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func copySSHCommand(_ item: VMItem) {
        guard let ip = item.ip else { return }
        NSPasteboard.general.clearContents()
        let command = "ssh \(item.meta.effectiveCloudInit.user)@\(ip)"
        NSPasteboard.general.setString(command, forType: .string)
        status = "Copied: \(command)"
    }
}

