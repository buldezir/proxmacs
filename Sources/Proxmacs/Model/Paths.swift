import Foundation

/// Filesystem layout. Proxmacs owns everything under `support` (always on the internal disk) and
/// `backups`; Tart owns `tartHome`. VM storage and backups can be moved elsewhere (see Storage).
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// `PROXMACS_SUPPORT_DIR` overrides the data directory (development/testing).
    static let support: URL = {
        if let custom = ProcessInfo.processInfo.environment["PROXMACS_SUPPORT_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home.appending(path: "Library/Application Support/Proxmacs", directoryHint: .isDirectory)
    }()
    static let images = support.appending(path: "images", directoryHint: .isDirectory)
    static let vms = support.appending(path: "vms", directoryHint: .isDirectory)
    static let defaultBackups = support.appending(path: "backups", directoryHint: .isDirectory)
    static var backups: URL {
        Storage.custom(.backups).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultBackups
    }

    static let launchAgents = home.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)

    static var tartHome: URL {
        if let custom = ProcessInfo.processInfo.environment["TART_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        if let custom = Storage.custom(.vms) { return URL(fileURLWithPath: custom, isDirectory: true) }
        return defaultTartHome
    }
    static let defaultTartHome = home.appending(path: ".tart", directoryHint: .isDirectory)

    static func vmDir(_ name: String) -> URL { vms.appending(path: name, directoryHint: .isDirectory) }
    static func metaFile(_ name: String) -> URL { vmDir(name).appending(path: "meta.json") }
    static func seedISO(_ name: String) -> URL { vmDir(name).appending(path: "seed.iso") }
    static func runLog(_ name: String) -> URL { vmDir(name).appending(path: "run.log") }
    /// Written by VMRunner once tart reports its VNC URL; read by the web VNC bridge.
    static func vncPortFile(_ name: String) -> URL { vmDir(name).appending(path: "vnc.port") }

    static func backupsDir(_ name: String) -> URL { backups.appending(path: name, directoryHint: .isDirectory) }

    static func tartVMDir(_ name: String) -> URL {
        tartHome.appending(path: "vms/\(name)", directoryHint: .isDirectory)
    }

    static func ensure() {
        // Custom storage is never created here: its drive may be disconnected.
        var dirs = [support, images, vms, launchAgents]
        if Storage.custom(.backups) == nil { dirs.append(defaultBackups) }
        for dir in dirs {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
