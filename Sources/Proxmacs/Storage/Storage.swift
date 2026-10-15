import Foundation

/// What can be relocated: VM disks (Tart's home directory) and local backups.
enum StorageKind: String, Codable, CaseIterable, Sendable {
    case vms, backups

    var label: String { self == .vms ? "VM storage" : "Backup storage" }
    /// For "Move …" titles.
    var noun: String { self == .vms ? "VM storage" : "backups" }
}

/// Custom locations; nil = the default on the internal disk. Stored in the data directory, which
/// always stays on the internal disk.
struct StorageSettings: Codable, Equatable {
    var vms: String?
    var backups: String?

    subscript(kind: StorageKind) -> String? {
        get { kind == .vms ? vms : backups }
        set { if kind == .vms { vms = newValue } else { backups = newValue } }
    }
}

/// A storage location as shown to the user.
struct StorageInfo {
    var kind: StorageKind
    var path: String
    var isDefault: Bool
    /// False when a custom location's drive is disconnected (its marker file is missing).
    var available: Bool
    var volume: VolumeInfo?
}

struct VolumeInfo {
    var path: String
    var name: String
    var fileSystem: String
    var isInternal: Bool
    var ejectable: Bool
    var freeBytes: Int64
    var totalBytes: Int64

    var isAPFS: Bool { fileSystem == "apfs" }
}

/// Custom storage locations live on external drives that can be disconnected. Each one carries a
/// marker file; without it the location counts as unavailable and nothing is read from or written
/// to it, so a missing drive never leads to VMs or backups being created on the internal disk under
/// /Volumes, or to Proxmacs treating the VMs as gone.
enum Storage {
    static let file = Paths.support.appending(path: "storage.json")
    static let markerName = ".proxmacs-storage"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached = StorageSettings()
    nonisolated(unsafe) private static var cachedStamp: Date?? = .none

    /// Re-read when the file changes, so the menubar app, `cli serve` and VM runners agree.
    static var settings: StorageSettings {
        lock.withLock {
            let stamp = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            if cachedStamp != .some(stamp) {
                cached = (try? JSONDecoder().decode(StorageSettings.self, from: Data(contentsOf: file))) ?? StorageSettings()
                cachedStamp = .some(stamp)
            }
            return cached
        }
    }

    static func save(_ settings: StorageSettings) throws {
        try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try JSONEncoder.proxmacs.encode(settings).write(to: file, options: .atomic)
        lock.withLock { cachedStamp = .none }
    }

    /// `TART_HOME` in the environment wins over the setting (development and testing).
    static var tartHomeOverridden: Bool {
        !(ProcessInfo.processInfo.environment["TART_HOME"] ?? "").isEmpty
    }

    static func custom(_ kind: StorageKind) -> String? {
        if kind == .vms && tartHomeOverridden { return nil }
        return settings[kind]
    }

    static func url(_ kind: StorageKind) -> URL {
        switch kind {
        case .vms: Paths.tartHome
        case .backups: Paths.backups
        }
    }

    static func marker(in directory: URL) -> URL { directory.appending(path: markerName) }

    static func isAvailable(_ kind: StorageKind) -> Bool {
        guard let path = custom(kind) else { return true }
        return FileManager.default.fileExists(atPath: marker(in: URL(fileURLWithPath: path, isDirectory: true)).path)
    }

    static func require(_ kind: StorageKind) throws {
        guard isAvailable(kind) else { throw unavailableError(kind) }
    }

    static func unavailableError(_ kind: StorageKind) -> ProxmacsError {
        ProxmacsError("\(kind.label) at \(url(kind).path) is not available. Connect the drive, or choose another location under Storage.")
    }

    static func info(_ kind: StorageKind) -> StorageInfo {
        let url = url(kind)
        let available = isAvailable(kind)
        return StorageInfo(kind: kind, path: url.path, isDefault: custom(kind) == nil, available: available,
                           volume: available ? volume(containing: url) : nil)
    }

    // MARK: Volumes

    /// The volume holding `url` (or its nearest existing ancestor).
    static func volume(containing url: URL) -> VolumeInfo? {
        var existing = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            existing.deleteLastPathComponent()
        }
        var fs = statfs()
        guard statfs(existing.path, &fs) == 0 else { return nil }
        let mountPoint = withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let fileSystem = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsEjectableKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        let values = try? existing.resourceValues(forKeys: keys)
        // The data volume of the startup disk is mounted at /System/Volumes/Data; show it as the startup disk.
        let shownPath = mountPoint == "/System/Volumes/Data" ? "/" : mountPoint
        return VolumeInfo(
            path: shownPath,
            name: values?.volumeLocalizedName ?? (shownPath as NSString).lastPathComponent,
            fileSystem: fileSystem,
            isInternal: values?.volumeIsInternal ?? false,
            ejectable: values?.volumeIsEjectable ?? false,
            // "Important usage" includes purgeable space but is 0 on some volumes (e.g. disk images).
            freeBytes: max(values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeAvailableCapacity ?? 0),
                           Int64(fs.f_bavail) * Int64(fs.f_bsize)),
            totalBytes: Int64(values?.volumeTotalCapacity ?? Int(Int64(fs.f_blocks) * Int64(fs.f_bsize)))
        )
    }

    /// Mounted, writable local volumes other than the startup disk: candidates for custom storage.
    static func externalVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey],
                                                         options: []) ?? []
        return urls.compactMap { url -> VolumeInfo? in
            let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey])
            // Drives mount under /Volumes (system volumes live elsewhere; dot-names are e.g. Time Machine snapshots).
            guard values?.volumeIsLocal == true, values?.volumeIsReadOnly != true, url.path.hasPrefix("/Volumes/"),
                  !url.lastPathComponent.hasPrefix(".") else { return nil }
            return volume(containing: url)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Choosing a location

    /// Absolute path with symlinks resolved as far as it exists (/tmp → /private/tmp), so paths compare reliably.
    static func canonical(_ url: URL) -> URL {
        var existing = URL(fileURLWithPath: url.path, isDirectory: true)
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let base = realpath(existing.path, &buffer) != nil ? String(cBuffer: buffer) : existing.path
        return rest.reduce(URL(fileURLWithPath: base, isDirectory: true)) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }

    static func canonical(path: String) -> URL {
        canonical(URL(fileURLWithPath: (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath).standardizedFileURL)
    }

    /// Checks that `path` can hold `kind` and returns it normalized. The directory may not exist yet,
    /// be empty, or already be a Proxmacs storage of the same kind (e.g. reconnecting a drive).
    static func validate(_ path: String, for kind: StorageKind) throws -> URL {
        let expanded = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw ProxmacsError("Enter an absolute path, e.g. /Volumes/External/Proxmacs/\(kind == .vms ? "VMs" : "Backups")") }
        let url = canonical(URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL)
        guard let volume = volume(containing: url) else { throw ProxmacsError("Cannot inspect \(url.path)") }
        guard url.path != volume.path, url.path != "/" else {
            throw ProxmacsError("Choose a folder on the drive, not the drive itself (e.g. \(volume.path == "/" ? "" : volume.path)/Proxmacs)")
        }
        guard volume.isAPFS else {
            throw ProxmacsError("\(volume.name) is formatted as \(volume.fileSystem). VM disks and backups need APFS (sparse files and instant clones); reformat the drive as APFS in Disk Utility.")
        }
        for other in StorageKind.allCases where other != kind {
            let otherPath = canonical(Storage.url(other)).path
            if url.path == otherPath || url.path.hasPrefix(otherPath + "/") || otherPath.hasPrefix(url.path + "/") {
                throw ProxmacsError("\(kind.label) and \(other.label) must be separate folders")
            }
        }
        if url.path.hasPrefix(canonical(Paths.support).path + "/") {
            throw ProxmacsError("Choose a folder outside the Proxmacs data directory (or use the default)")
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw ProxmacsError("\(url.path) is a file") }
            if let existing = markerKind(url) {
                guard existing == kind else { throw ProxmacsError("\(url.path) holds Proxmacs \(existing.label.lowercased()), not \(kind.label.lowercased())") }
            } else {
                let ignored: Set<String> = [".DS_Store", ".localized"]
                let contents = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { !ignored.contains($0) }
                guard contents.isEmpty else { throw ProxmacsError("\(url.path) is not empty. Choose an empty or new folder.") }
            }
        }
        guard access(volume.path == "/" ? Paths.home.path : volume.path, W_OK) == 0 else {
            throw ProxmacsError("\(volume.name) is not writable")
        }
        return url
    }

    static func markerKind(_ directory: URL) -> StorageKind? {
        guard let data = try? Data(contentsOf: marker(in: directory)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["kind"] as? String).flatMap(StorageKind.init)
    }

    /// Creates the directory and its marker.
    static func prepare(_ url: URL, for kind: StorageKind) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if markerKind(url) == nil {
            let json: [String: Any] = ["kind": kind.rawValue, "created": Date().ISO8601Format(),
                                       "note": "Proxmacs \(kind.label.lowercased()). Do not delete this file."]
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: marker(in: url))
        }
    }
}
