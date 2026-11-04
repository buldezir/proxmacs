import Foundation

struct BackupRecord: Codable, Hashable {
    var date: Date
    /// True when the guest filesystem was frozen during the snapshot (or the VM was stopped).
    var consistent: Bool
    var vmWasRunning: Bool
    /// Offsite target name when the backup was pulled from a remote snapshot.
    var source: String? = nil
}

struct BackupInfo: Identifiable, Hashable {
    var url: URL
    var record: BackupRecord
    var id: String { url.path }
    /// Directory name; stable id used by the web API.
    var name: String { url.lastPathComponent }
}

/// Backups are APFS clones of Tart's VM files: instant and copy-on-write when backups share the
/// VM storage volume. When they don't (e.g. backups on an external drive), the files are cloned to a
/// staging area on the VM volume while the guest is frozen, then copied over after it thaws, so
/// the guest is never frozen for longer than a clone takes.
enum BackupManager {
    static let vmFiles = ["disk.img", "nvram.bin", "config.json"]
    private static let recordFile = "backup.json"

    /// Tart files plus the extra disks marked for backup.
    static func files(of vm: String) -> [String] {
        vmFiles + (VMMeta.load(vm)?.disks ?? []).filter(\.backup).map(\.file)
    }

    /// Empty while backup storage is unavailable.
    static func list(_ vm: String) -> [BackupInfo] {
        guard Storage.isAvailable(.backups) else { return [] }
        let dir = Paths.backupsDir(vm)
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { url in
            guard let data = try? Data(contentsOf: url.appending(path: recordFile)),
                  let record = try? JSONDecoder.proxmacs.decode(BackupRecord.self, from: data) else { return nil }
            return BackupInfo(url: url, record: record)
        }.sorted { $0.record.date > $1.record.date }
    }

    /// Scratch space on the VM storage volume, where clones are instant.
    static func stagingDir() throws -> URL {
        let dir = Paths.tartHome.appending(path: ".proxmacs-staging/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func removeStaging(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        rmdir(dir.deletingLastPathComponent().path)  // only succeeds once empty
    }

    /// Clones `files` of the VM into `directory` (on the VM storage volume, so instantly). While the VM runs,
    /// the guest's root filesystem is frozen through the agent for the clone; returns whether it was. macOS has no
    /// freeze, so a running macOS guest only syncs and its copy is crash-consistent.
    static func snapshot(_ vm: String, files: [String], into directory: URL, running: Bool, tart: Tart) async throws -> Bool {
        let source = Paths.tartVMDir(vm)
        var frozen = false
        if running, (try? await tart.exec(vm, ["sync"]))?.succeeded == true, GuestOS.of(vm) != .darwin {
            frozen = (try? await tart.exec(vm, ["fsfreeze", "--freeze", "/"]))?.succeeded == true
        }
        do {
            for file in files {
                try clone(source.appending(path: file), to: directory.appending(path: file))
            }
        } catch {
            if frozen { await thaw(vm, tart: tart) }
            throw error
        }
        if frozen { await thaw(vm, tart: tart) }
        return frozen
    }

    static func backup(_ vm: String, running: Bool, tart: Tart, policy: BackupPolicy,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> BackupInfo {
        try Storage.require(.backups)
        try Storage.require(.vms)
        let date = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let target = Paths.backupsDir(vm).appending(path: formatter.string(from: date), directoryHint: .isDirectory)
        let direct = FileCopy.sameVolume(Paths.tartVMDir(vm), Paths.backups)
        // Snapshot first into `target` (same volume) or a staging directory next to the VM.
        let snapshotDir = direct ? target : try stagingDir()
        defer { if !direct { removeStaging(snapshotDir) } }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let files = files(of: vm)

        var frozen = false
        do {
            // Freeze the root filesystem through the guest agent so the clone is filesystem-consistent.
            frozen = try await snapshot(vm, files: files, into: snapshotDir, running: running, tart: tart)

            if !direct {
                let snapshot = snapshotDir
                let total = Double(max(FileCopy.size(of: snapshot), 1))
                try await Task.detached(priority: .userInitiated) {
                    var done: Int64 = 0
                    for file in files {
                        try FileCopy.copy(snapshot.appending(path: file), to: target.appending(path: file)) { bytes in
                            done += bytes
                            progress?(Double(done) / total)
                        }
                    }
                }.value
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }

        if FileManager.default.fileExists(atPath: Paths.metaFile(vm).path) {
            try? clone(Paths.metaFile(vm), to: target.appending(path: "meta.json"))
        }
        let record = BackupRecord(date: date, consistent: !running || frozen, vmWasRunning: running)
        try JSONEncoder.proxmacs.encode(record).write(to: target.appending(path: recordFile))

        prune(vm, policy: policy)
        return BackupInfo(url: target, record: record)
    }

    /// Backs up straight to an offsite target, without a local backup: the VM's files are cloned next to the
    /// VM (frozen as for a local backup), pushed from there, and the clone removed.
    static func backup(_ vm: String, running: Bool, tart: Tart, to backend: OffsiteBackend,
                       progress: @escaping ProgressHandler) async throws -> BackupRecord {
        try Storage.require(.vms)
        let date = Date()
        let stage = try stagingDir()
        defer { removeStaging(stage) }
        let frozen = try await snapshot(vm, files: files(of: vm), into: stage, running: running, tart: tart)
        if FileManager.default.fileExists(atPath: Paths.metaFile(vm).path) {
            try? clone(Paths.metaFile(vm), to: stage.appending(path: "meta.json"))
        }
        let record = BackupRecord(date: date, consistent: !running || frozen, vmWasRunning: running)
        try await backend.push(vm: vm, backupDir: stage, record: record, progress: progress)
        return record
    }

    /// Extra disk images in a backup (disk1.img, …).
    static func extraDisks(in backup: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: backup.path)) ?? []).filter(ExtraDisk.isValidFile).sorted()
    }

    /// The VM must be stopped. Restores the root disk, NVRAM and every extra disk in the backup; returns
    /// the extra disks restored.
    @discardableResult
    static func restore(_ vm: String, from backup: BackupInfo, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [String] {
        try Storage.require(.backups)
        let extra = extraDisks(in: backup.url)
        let total = Double(max(([BackupFiles.disk] + extra).reduce(Int64(0)) { $0 + FileCopy.size(of: backup.url.appending(path: $1)) }, 1))
        let done = Counter()
        for file in [BackupFiles.disk] + extra {
            let size = Double(FileCopy.size(of: backup.url.appending(path: file)))
            let base = done.value
            try await setDisk(vm, file: file, from: backup.url.appending(path: file), create: true) { fraction in
                progress?(min((base + fraction * size) / total, 1))
            }
            done.value += size
        }
        let nvram = Paths.tartVMDir(vm).appending(path: "nvram.bin")
        try? FileManager.default.removeItem(at: nvram)
        try clone(backup.url.appending(path: "nvram.bin"), to: nvram)
        return extra
    }

    private final class Counter: @unchecked Sendable { var value: Double = 0 }

    /// Replaces the VM's disk with a copy of `source`, as `tart set --disk` does (copy next to the VM,
    /// then swap it in). Done here rather than by Tart because Tart 2.x breaks when TART_HOME contains a
    /// space (e.g. "/Volumes/My Drive"), and so a disk from another volume is copied sparsely: a clone
    /// on the same volume, only the data regions across volumes.
    static func setDisk(_ vm: String, file: String = "disk.img", from source: URL, create: Bool = false,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let disk = Paths.tartVMDir(vm).appending(path: file)
        guard create || FileManager.default.fileExists(atPath: disk.path) else { throw ProxmacsError("VM \(vm) has no disk at \(disk.path)") }
        let temporary = disk.deletingLastPathComponent().appending(path: ".disk.img.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let total = Double(max(FileCopy.size(of: source), 1))
        try await Task.detached(priority: .userInitiated) {
            var done: Int64 = 0
            try FileCopy.copy(source, to: temporary) { bytes in
                done += bytes
                progress?(Double(done) / total)
            }
        }.value
        guard rename(temporary.path, disk.path) == 0 else {
            throw ProxmacsError("Cannot replace \(disk.path): \(String(cString: strerror(errno)))")
        }
    }

    static func delete(_ backup: BackupInfo) throws {
        try Storage.require(.backups)
        try FileManager.default.removeItem(at: backup.url)
    }

    static func prune(_ vm: String, policy: BackupPolicy) {
        let backups = list(vm)
        let kept = Retention.kept(backups.map(\.record.date), policy: policy)
        for (index, old) in backups.enumerated() where !kept.contains(index) {
            try? delete(old)
        }
    }

    static func thaw(_ vm: String, tart: Tart) async {
        // Never leave the guest frozen: retry a few times.
        for attempt in 0..<5 {
            if (try? await tart.exec(vm, ["fsfreeze", "--unfreeze", "/"], timeout: 15))?.succeeded == true { return }
            try? await Task.sleep(for: .seconds(Double(attempt + 1)))
        }
    }

    /// Small files (and same-volume disks): clone, or plain copy across volumes.
    private static func clone(_ source: URL, to destination: URL) throws {
        try FileCopy.copy(source, to: destination)
    }
}
