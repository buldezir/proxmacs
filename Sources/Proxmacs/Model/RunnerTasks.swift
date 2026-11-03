import Foundation

/// Tasks recorded by a VM's runner (`cli run-vm`, see VMRunner), such as a restart after a crash.
/// The runner is a process of its own, so it writes them next to the VM's metadata, and the app
/// merges them into its task log (`AppState.refresh`).
enum RunnerTasks {
    static func url(_ vm: String) -> URL { Paths.vmDir(vm).appending(path: "tasks.json") }
    private static let limit = 20

    static func load(_ vm: String) -> [TaskRecord] {
        guard let data = try? Data(contentsOf: url(vm)) else { return [] }
        return (try? JSONDecoder().decode([TaskRecord].self, from: data)) ?? []
    }

    /// Adds `record`, or replaces the one with its id, keeping the newest few.
    static func save(_ vm: String, _ record: TaskRecord) {
        var records = load(vm).filter { $0.id != record.id }
        records.append(record)
        records = Array(records.sorted { $0.started < $1.started }.suffix(limit))
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url(vm), options: .atomic)
    }
}

extension TaskRecord {
    mutating func finish(_ status: Status, _ message: String?) {
        self.status = status
        self.message = message
        finished = Date()
        if status == .ok { progress = 1 }
    }
}
