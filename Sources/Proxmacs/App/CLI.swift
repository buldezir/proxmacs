import Foundation

@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "cli" {
            CLI.run(Array(args.dropFirst()))
        } else {
            FileHandle.standardError.write("headless build: use Proxmacs cli ...\n".data(using: .utf8)!)
            exit(2)
        }
    }
}

/// `Proxmacs cli <command>`: scriptable access to the same AppState the menubar uses.
enum CLI {
    static let usage = """
    usage: Proxmacs cli <command>
      list
      create <name> [--nat | --bridged <iface>] [--cpus N] [--memory MB] [--disk GB]
                    [--image <id|file.qcow2|raw>] [--password P] [--autostart] [--no-start]
                    [--user U] [--ssh-keys FILE] [--ip CIDR [--gateway IP] [--dns IP,IP]]
      edit <name>   hardware (VM stopped): [--cpus N] [--memory MB] [--disk GB] [--nat | --bridged <iface>]
                    cloud-init (applied on next start): [--user U] [--password | --no-password]
                    [--ssh-keys FILE] [--dhcp | --ip CIDR [--gateway IP] [--dns IP,IP]]
      start|delete <name>
      backup <name> [--to <target>]    local backup, or straight to an offsite target
      stop <name> [--force]            shut down (--force: turn off at once)
      reboot <name> [--force]          reboot through the guest agent (--force: reset)
      info <name>                      settings, usage and what the guest agent reports
      ip <name> [--wait SECONDS]
      clone <name> <new> [--start] [--dhcp | --ip CIDR [--gateway IP] [--dns IP,IP]]
      template <name> [--off]          make a VM a template (clone-only), or a VM again
      set <name>    [--tags a,b] [--notes TEXT|-] [--autostart on|off] [--order N|none] [--delay SECONDS]
                    [--nested on|off] [--keep-last N] [--keep-daily N] [--keep-weekly N] [--keep-monthly N] [--keep-yearly N]
      disk-add <name> <GB> [--no-backup] | disk-resize <name> <diskN.img> <GB> | disk-rm <name> <diskN.img>
      share-add <name> <share> <folder> [--ro] | share-rm <name> <share>
                                       host folders, mounted in the guest at /mnt/shared/<share>
      backups <name>
      restore <name> [index]      (0 = newest, as listed by `backups`)

      jobs                             list backup jobs
      job-add [--at HH:MM] [--days mon,tue,…|weekdays|weekends] [--vms a,b | --exclude a,b]
              [--to <target>] [--notify never|failure|always] [--comment TEXT]
      job-rm|job-run <id>
      notify                           list notification webhooks
      notify-add <name> [--format json|discord|slack|ntfy]   add a webhook (prompts for its URL)
      notify-rm|notify-test <name>

      images                           list cloud images (catalog and imported)
      image-pull <id>                  download and cache an image ahead of creating VMs
      image-rm <id>                    remove a cached image

      targets
      target-add smb <name> <smb://user@host/share[/path]> [--keep N]        (prompts for the password)
      target-add pbs <name> --host H --datastore D --auth-id user@realm!token
                     [--port 8007] [--namespace NS] [--fingerprint aa:bb:..] [--keep N]  (prompts for the token secret)
      target-rm|target-test <target>
      push <name> <target> [index]     upload a local backup (default newest)
      remote <target> <name>           list remote snapshots
      pull <target> <name> [id]        download a snapshot into local backups (default newest);
                                       recreates the VM if it doesn't exist
      verify <target> <name> [id]      read a remote snapshot back and check every chunk (default newest)

      storage                          show where VM disks and local backups are stored
      storage vms|backups <folder>     move them to a folder, e.g. on an external APFS drive
      storage vms|backups --default    move them back to the internal disk

      console <name>                   attach to the serial console (Ctrl-] detaches)
      web-passwd [--stdin]             set the web UI admin password
      api-keys                         list API keys (docs/API.md)
      api-key-add <name>               create an API key; it is printed once
      api-key-rm <name|id>             revoke an API key
      serve                            run the web UI headless (no menubar)
    """

    static func run(_ args: [String]) -> Never {
        if args.first == "run-vm", args.count > 1 {
            do { try VMRunner.run(args[1]) } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        if args.first == "console", args.count > 1 {
            attachConsole(args[1])
        }
        Task { @MainActor in
            do {
                try await execute(args)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    @MainActor
    private static func execute(_ args: [String]) async throws {
        let state = AppState(autoRefresh: false)
        state.onStatus = { print($0) }
        await state.refresh()
        guard let command = args.first else { throw ProxmacsError(usage) }

        func name() throws -> String {
            guard args.count > 1 else { throw ProxmacsError(usage) }
            return args[1]
        }
        func option(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        /// One OpenSSH public key per line; `-` reads stdin.
        func sshKeys(_ path: String) throws -> [String] {
            let text = path == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                : try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
            return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        func guestNetwork(_ base: GuestNetwork) -> GuestNetwork {
            if args.contains("--dhcp") { return GuestNetwork() }
            guard let address = option("--ip") else { return base }
            return GuestNetwork(dhcp: false, address: address, gateway: option("--gateway"),
                                dns: option("--dns")?.split(separator: ",").map(String.init) ?? [])
        }
        func check() throws {
            if let error = state.lastError { throw ProxmacsError(error) }
        }

        switch command {
        case "list":
            for vm in state.vms {
                let tags = vm.meta.tags.isEmpty ? "" : " [\(vm.meta.tags.joined(separator: ","))]"
                print([vm.name + tags, vm.meta.template ? "template" : vm.state, vm.meta.network.label, vm.ip ?? "-"].joined(separator: "\t"))
            }

        case "info":
            let vm = try name()
            guard let item = state.vms.first(where: { $0.name == vm }) else { throw ProxmacsError("No VM named \(vm)") }
            let meta = item.meta
            var rows: [(String, String)] = [
                ("state", meta.template ? "template" : item.state), ("network", meta.network.label), ("ip", item.ip ?? "-"),
                ("cpus", item.cpus.map(String.init) ?? "-"), ("memory", item.memoryMB.map { "\($0) MB" } ?? "-"),
                ("disk", item.diskGB.map { "\($0) GB" } ?? "-"),
            ]
            for disk in meta.disks {
                rows.append((disk.file, "\(AppState.diskGB(Paths.tartVMDir(vm).appending(path: disk.file))) GB\(disk.backup ? "" : ", not backed up")"))
            }
            for share in meta.shares { rows.append(("share \(share.name)", share.path + (share.readOnly ? " (read-only)" : ""))) }
            if meta.nested { rows.append(("nested", "on")) }
            rows.append(("autostart", meta.autostart ? "on" + (meta.startOrder.map { ", order \($0)" } ?? "") + (meta.startDelay > 0 ? ", delay \(meta.startDelay) s" : "") : "off"))
            rows.append(("retention", meta.backup.label))
            if !meta.tags.isEmpty { rows.append(("tags", meta.tags.joined(separator: ", "))) }
            if !meta.notes.isEmpty { rows.append(("notes", meta.notes.replacingOccurrences(of: "\n", with: " / "))) }
            if item.isRunning, let guest = try? await state.guestInfo(vm) {
                rows.append(("os", guest.os ?? "-"))
                rows.append(("kernel", guest.kernel ?? "-"))
                if let uptime = guest.uptime { rows.append(("uptime", Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow)))) }
                for interface in guest.interfaces {
                    rows.append((interface.name, ([interface.mac ?? ""] + interface.addresses).joined(separator: " ")))
                }
                for fs in guest.filesystems {
                    rows.append((fs.mount, "\(ByteCountFormatter.string(fromByteCount: Int64(fs.used), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(fs.size), countStyle: .file)) (\(fs.type))"))
                }
            }
            for (key, value) in rows { print("\(key)\t\(value)") }

        case "clone":
            guard args.count > 2 else { throw ProxmacsError(usage) }
            let network: GuestNetwork? = args.contains("--dhcp") || args.contains("--ip") ? guestNetwork(GuestNetwork()) : nil
            try await state.clone(args[1], to: args[2], start: args.contains("--start"), network: network)

        case "template":
            try state.setTemplate(try name(), !args.contains("--off"))

        case "set":
            let vm = try name()
            func toggle(_ flag: String) throws -> Bool? {
                guard let value = option(flag) else { return nil }
                guard ["on", "off"].contains(value) else { throw ProxmacsError("\(flag) takes on or off") }
                return value == "on"
            }
            func count(_ flag: String) throws -> Int? {
                guard let value = option(flag) else { return nil }
                guard let n = Int(value), n >= 0 else { throw ProxmacsError("\(flag) takes a number") }
                return n
            }
            let tags = try option("--tags").map { list in
                try list.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }.map { tag in
                    guard VMMeta.isValidTag(tag) else { throw ProxmacsError("Invalid tag \(tag)") }
                    return tag
                }
            }
            let notes = option("--notes").map { $0 == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : $0 }
            let order: Int?? = try option("--order").map { value -> Int? in
                if value == "none" { return nil }
                guard let n = Int(value), (0...9999).contains(n) else { throw ProxmacsError("--order takes 0–9999 or none") }
                return n
            }
            let delay = try count("--delay")
            if let delay, delay > 3600 { throw ProxmacsError("--delay is at most 3600 seconds") }
            let autostart = try toggle("--autostart")
            let keeps = try ["--keep-last", "--keep-daily", "--keep-weekly", "--keep-monthly", "--keep-yearly"].map(count)
            if let nested = try toggle("--nested") { try await state.editHardware(vm, HardwareChange(nested: nested)) }
            if autostart == true, VMMeta.load(vm)?.template == true { throw ProxmacsError("Templates can't start on login") }
            try state.updateMeta(vm) { meta in
                if let tags { meta.tags = tags }
                if let notes { meta.notes = notes.trimmingCharacters(in: .newlines) }
                if let order { meta.startOrder = order }
                if let delay { meta.startDelay = delay }
                if let autostart { meta.autostart = autostart }
                if let n = keeps[0] { meta.backup.keep = n }
                if let n = keeps[1] { meta.backup.keepDaily = n }
                if let n = keeps[2] { meta.backup.keepWeekly = n }
                if let n = keeps[3] { meta.backup.keepMonthly = n }
                if let n = keeps[4] { meta.backup.keepYearly = n }
            }

        case "disk-add":
            guard args.count > 2, let size = Int(args[2]) else { throw ProxmacsError(usage) }
            let file = try state.addDisk(args[1], sizeGB: size)
            if args.contains("--no-backup") { try state.setDiskBackup(args[1], file: file, backup: false) }
            print("added \(file)")
        case "disk-resize":
            guard args.count > 3, let size = Int(args[3]) else { throw ProxmacsError(usage) }
            try state.resizeDisk(args[1], file: args[2], sizeGB: size)
        case "disk-rm":
            guard args.count > 2 else { throw ProxmacsError(usage) }
            try state.removeDisk(args[1], file: args[2])
        case "share-add":
            guard args.count > 3 else { throw ProxmacsError(usage) }
            try await state.addShare(args[1], SharedFolder(name: args[2], path: args[3], readOnly: args.contains("--ro")))
        case "share-rm":
            guard args.count > 2 else { throw ProxmacsError(usage) }
            try state.removeShare(args[1], name: args[2])

        case "jobs":
            for job in JobStore.load() {
                let selection = switch job.selection {
                case .all: "all VMs"
                case .include: job.vms.joined(separator: ",")
                case .exclude: "all except \(job.vms.joined(separator: ","))"
                }
                let last = job.lastRun.map { "last \($0.formatted(.iso8601)) \(job.lastOK == true ? "ok" : "failed")" } ?? "never run"
                let destination = job.target.map { "to \(TargetStore.target($0)?.name ?? $0)" } ?? "local"
                print([job.id, job.enabled ? job.scheduleLabel : "disabled", selection, destination, "notify \(job.notify.rawValue)", last, job.comment]
                    .joined(separator: "\t"))
            }
        case "job-add":
            var job = BackupJob()
            if let at = option("--at") {
                let parts = at.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { throw ProxmacsError("--at takes HH:MM") }
                (job.hour, job.minute) = (parts[0], parts[1])
            }
            if let days = option("--days") {
                switch days {
                case "daily": job.days = []
                case "weekdays": job.days = [1, 2, 3, 4, 5]
                case "weekends": job.days = [6, 7]
                default:
                    job.days = try days.split(separator: ",").map { day in
                        guard let index = BackupJob.dayNames.firstIndex(where: { $0.lowercased() == day.lowercased().prefix(3) }) else {
                            throw ProxmacsError("Unknown day \(day)")
                        }
                        return index + 1
                    }
                }
            }
            if let vms = option("--vms") { job.selection = .include; job.vms = vms.split(separator: ",").map(String.init) }
            if let vms = option("--exclude") { job.selection = .exclude; job.vms = vms.split(separator: ",").map(String.init) }
            if let notify = option("--notify") {
                guard let value = NotifyWhen(rawValue: notify) else { throw ProxmacsError("--notify takes never, failure or always") }
                job.notify = value
            }
            job.comment = option("--comment") ?? ""
            if let value = option("--to") {
                guard let target = TargetStore.target(value) else { throw ProxmacsError("No backup target \(value)") }
                job.target = target.id
            }
            try JobStore.upsert(job)
            print("added job \(job.id): \(job.scheduleLabel)")
        case "job-rm":
            try JobStore.remove(try name())
        case "job-run":
            guard JobStore.job(try name()) != nil else { throw ProxmacsError("No job \(args[1])") }
            await state.runJob(args[1])
            if JobStore.job(args[1])?.lastOK != true { throw ProxmacsError(JobStore.job(args[1])?.lastMessage ?? "job failed") }

        case "notify":
            for target in NotificationStore.load() {
                print([target.name, target.location, target.enabled ? "enabled" : "disabled", target.id].joined(separator: "\t"))
            }
        case "notify-add":
            var target = NotificationTarget(name: try name())
            if let format = option("--format") {
                guard let value = NotificationTarget.Format(rawValue: format) else { throw ProxmacsError("Unknown format \(format)") }
                target.format = value
            }
            try NotificationStore.upsert(target, url: prompt("Webhook URL: "))
            print("added webhook \(target.name)")
        case "notify-rm":
            guard let target = NotificationStore.target(try name()) else { throw ProxmacsError("No notification target \(args[1])") }
            try NotificationStore.remove(target.id)
        case "notify-test":
            guard let target = NotificationStore.target(try name()) else { throw ProxmacsError("No notification target \(args[1])") }
            try await Notifier.send(target, title: "Proxmacs test notification",
                                    message: "Notifications from \(ProcessInfo.processInfo.hostName) reach this target.", failed: false)
            print("sent")

        case "create":
            let vm = try name()
            let network: NetworkMode = if args.contains("--nat") {
                .nat
            } else if let iface = option("--bridged") {
                .bridged(interface: iface)
            } else {
                .bridged(interface: await NetworkInterfaces.defaultRoute() ?? "en0")
            }
            let image: ImageSource = try option("--image").map { value in
                if let named = ImageSource.named(value) { return named }
                let path = (value as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: path) else {
                    throw ProxmacsError("No image or file \(value) (see `images`)")
                }
                return .local(URL(fileURLWithPath: path))
            } ?? .default
            let defaultUser = if case .catalog(let catalog) = image { catalog.user } else { "debian" }
            let request = NewVMRequest(
                name: vm,
                cpus: option("--cpus").flatMap(Int.init) ?? 2,
                memoryMB: option("--memory").flatMap(Int.init) ?? 2048,
                diskGB: option("--disk").flatMap(Int.init) ?? 20,
                network: network,
                image: image,
                password: option("--password") ?? "",
                autostart: args.contains("--autostart"),
                startNow: !args.contains("--no-start"),
                user: option("--user") ?? defaultUser,
                sshKeys: try option("--ssh-keys").map(sshKeys),
                guestNetwork: guestNetwork(GuestNetwork())
            )
            try await state.create(request)
            print("created \(vm) (\(network.label))")

        case "images":
            let downloads = ImageDownloads.shared.progress()
            for image in ImageStore.entries() {
                let status = if let download = downloads[image.id] {
                    download.message
                } else if image.cached, let disk = image.diskBytes {
                    "cached, \(ByteCountFormatter.string(fromByteCount: disk, countStyle: .memory)) on disk"
                } else {
                    "-"
                }
                print([image.id, image.catalog == nil ? "imported" : image.name, image.catalog?.user ?? "-", status].joined(separator: "\t"))
            }

        case "image-pull":
            let id = try name()
            guard let image = ImageCatalog.find(id) else { throw ProxmacsError("No image \(id) (see `images`)") }
            try await state.downloadImage(image)

        case "image-rm":
            try state.deleteImage(try name())

        case "edit":
            let vm = try name()
            guard let meta = VMMeta.load(vm) else { throw ProxmacsError("No VM named \(vm)") }
            let network: NetworkMode? = if args.contains("--nat") {
                .nat
            } else {
                option("--bridged").map { .bridged(interface: $0) }
            }
            let hardware = HardwareChange(cpus: option("--cpus").flatMap(Int.init), memoryMB: option("--memory").flatMap(Int.init),
                                          diskGB: option("--disk").flatMap(Int.init), network: network)
            var edited = false
            if hardware.cpus != nil || hardware.memoryMB != nil || hardware.diskGB != nil || hardware.network != nil {
                try await state.editHardware(vm, hardware)
                edited = true
            }
            let cloudFlags = ["--user", "--password", "--no-password", "--ssh-keys", "--dhcp", "--ip"]
            if cloudFlags.contains(where: args.contains) {
                let current = meta.effectiveCloudInit
                var password = PasswordChange.keep
                if args.contains("--no-password") {
                    password = .remove
                } else if args.contains("--password") {
                    let first = prompt("New console password for \(option("--user") ?? current.user): ")
                    guard first == prompt("Repeat: ") else { throw ProxmacsError("Passwords don't match") }
                    password = .set(first)
                }
                try await state.editCloudInit(vm, user: option("--user") ?? current.user, password: password,
                                              sshKeys: try option("--ssh-keys").map(sshKeys) ?? current.sshKeys,
                                              network: guestNetwork(current.network))
                edited = true
            }
            if !edited { throw ProxmacsError(usage) }

        case "start":
            await state.start(try name()); try check()
        case "stop":
            await state.stop(try name(), force: args.contains("--force")); try check()
        case "reboot":
            await state.reboot(try name(), force: args.contains("--force")); try check()
        case "delete":
            await state.delete(try name()); try check()
        case "backup":
            let target = try option("--to").map { value in
                guard let target = TargetStore.target(value) else { throw ProxmacsError("No backup target \(value)") }
                return target.id
            }
            if target != nil { printProgress(state) }
            await state.backup(try name(), to: target); try check()

        case "ip":
            let vm = try name()
            let deadline = Date().addingTimeInterval(option("--wait").flatMap(TimeInterval.init) ?? 0)
            while true {
                if let ip = state.vms.first(where: { $0.name == vm })?.ip {
                    print(ip)
                    return
                }
                if Date() >= deadline { throw ProxmacsError("no IP for \(vm)") }
                try await Task.sleep(for: .seconds(3))
                await state.refresh()
            }

        case "backups":
            try Storage.require(.backups)
            for (index, backup) in BackupManager.list(try name()).enumerated() {
                print("\(index)\t\(backup.record.date.formatted(.iso8601))\t\(backup.record.consistent ? "consistent" : "crash-consistent")")
            }

        case "restore":
            let vm = try name()
            let index = args.count > 2 ? Int(args[2]) ?? 0 : 0
            try Storage.require(.backups)
            let backups = BackupManager.list(vm)
            guard backups.indices.contains(index) else { throw ProxmacsError("no backup #\(index) for \(vm)") }
            await state.restore(vm, backups[index]); try check()

        case "targets":
            for target in TargetStore.load() {
                print([target.name, target.kind.rawValue, target.location, "keep \(target.keep)", target.id].joined(separator: "\t"))
            }

        case "target-add":
            guard args.count > 3 else { throw ProxmacsError(usage) }
            let kind = args[1], targetName = args[2]
            let keep = option("--keep").flatMap(Int.init) ?? 7
            switch kind {
            case "smb":
                _ = try SMBLocation(parsing: args[3])
                let password = prompt("SMB password (empty = none/guest): ")
                try state.addTarget(OffsiteTarget(name: targetName, kind: .smb, keep: keep, smb: SMBSettings(url: args[3])), secret: password)
            case "pbs":
                guard let host = option("--host"), let datastore = option("--datastore"), let authId = option("--auth-id") else {
                    throw ProxmacsError(usage)
                }
                let settings = PBSSettings(host: host, port: option("--port").flatMap(Int.init) ?? 8007, datastore: datastore,
                                           namespace: option("--namespace"), authId: authId, fingerprint: option("--fingerprint"))
                let secret = prompt("PBS API token secret: ")
                guard !secret.isEmpty else { throw ProxmacsError("A token secret is required") }
                try state.addTarget(OffsiteTarget(name: targetName, kind: .pbs, keep: keep, pbs: settings), secret: secret)
            default:
                throw ProxmacsError(usage)
            }
            print("added target \(targetName)")

        case "target-rm":
            guard let target = TargetStore.target(try name()) else { throw ProxmacsError("no such target") }
            try state.removeTarget(target.id)

        case "target-test":
            guard let target = TargetStore.target(try name()) else { throw ProxmacsError("no such target") }
            let result = await state.testTarget(target.id)
            print(result.message)
            if !result.ok { throw ProxmacsError("test failed") }

        case "push":
            guard args.count > 2, let target = TargetStore.target(args[2]) else { throw ProxmacsError(usage) }
            let vm = args[1]
            let index = args.count > 3 ? Int(args[3]) ?? 0 : 0
            let backups = BackupManager.list(vm)
            guard backups.indices.contains(index) else { throw ProxmacsError("no backup #\(index) for \(vm)") }
            printProgress(state)
            await state.push(vm, backup: backups[index], targetID: target.id); try check()

        case "remote":
            guard args.count > 2, let target = TargetStore.target(args[1]) else { throw ProxmacsError(usage) }
            for snapshot in try await state.remoteSnapshots(targetID: target.id, vm: args[2]) {
                print("\(snapshot.id)\t\(snapshot.time.formatted(.iso8601))")
            }

        case "pull":
            guard args.count > 2, let target = TargetStore.target(args[1]) else { throw ProxmacsError(usage) }
            let vm = args[2]
            var id = args.count > 3 ? args[3] : nil
            if id == nil { id = try await state.remoteSnapshots(targetID: target.id, vm: vm).first?.id }
            guard let id else { throw ProxmacsError("no snapshots of \(vm) on \(target.name)") }
            printProgress(state)
            await state.pull(vm, snapshotID: id, targetID: target.id); try check()

        case "verify":
            guard args.count > 2, let target = TargetStore.target(args[1]) else { throw ProxmacsError(usage) }
            let vm = args[2]
            var id = args.count > 3 ? args[3] : nil
            if id == nil { id = try await state.remoteSnapshots(targetID: target.id, vm: vm).first?.id }
            guard let id else { throw ProxmacsError("no snapshots of \(vm) on \(target.name)") }
            printProgress(state)
            await state.verify(vm, snapshotID: id, targetID: target.id); try check()

        case "storage":
            if args.count == 1 {
                for kind in StorageKind.allCases {
                    let info = Storage.info(kind)
                    var line = "\(kind.rawValue)\t\(info.path)"
                    if info.isDefault { line += "  (default)" }
                    if !info.available {
                        line += "  UNAVAILABLE (drive disconnected?)"
                    } else if let volume = info.volume {
                        line += "  [\(volume.name), \(volume.fileSystem), \(ByteCountFormatter.string(fromByteCount: volume.freeBytes, countStyle: .file)) free]"
                    }
                    print(line)
                }
                return
            }
            guard args.count > 2, let kind = StorageKind(rawValue: args[1]) else { throw ProxmacsError(usage) }
            let plan = try await state.planStorageChange(kind, to: args[2] == "--default" ? nil : args[2])
            printProgress(state)
            try await state.changeStorage(plan)

        case "web-passwd":
            if args.contains("--stdin") {
                // For provisioning scripts: password on the first line of stdin.
                try WebAuth.setPassword(readLine(strippingNewline: true) ?? "")
                print("Password set.")
                return
            }
            let first = prompt("New web UI admin password: ")
            guard first == prompt("Repeat: ") else { throw ProxmacsError("Passwords don't match") }
            try WebAuth.setPassword(first)
            print("Password set.")

        case "api-keys":
            let used = APIKeyStore.shared.lastUsed()
            for key in APIKeyStore.shared.load() {
                print([key.name, key.prefix + "…", "created " + key.created.formatted(date: .abbreviated, time: .shortened),
                       used[key.id].map { "last used " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "never used", key.id]
                    .joined(separator: "\t"))
            }

        case "api-key-add":
            let created = try APIKeyStore.shared.create(name: try name())
            // The key alone on stdout, so scripts can capture it; the note goes to stderr.
            FileHandle.standardError.write(Data("API key \(created.key.name) created. It isn't stored: keep it now.\n".utf8))
            print(created.secret)

        case "api-key-rm":
            try APIKeyStore.shared.remove(try name())
            print("Revoked.")

        case "serve":
            let served = AppState()
            WebServer.shared.start(state: served)
            try await Task.sleep(for: .seconds(1))
            if let error = WebServer.shared.lastError { throw ProxmacsError(error) }
            print("Proxmacs web UI on \(WebServer.shared.url ?? "?")")
            if let fingerprint = WebCertificate.fingerprint() { print("Certificate SHA-256: \(fingerprint)") }
            if !WebAuth.hasPassword { print("No admin password yet: run `Proxmacs cli web-passwd`.") }
            await WebServer.shared.wait()
            if let error = WebServer.shared.lastError { throw ProxmacsError(error) }

        default:
            throw ProxmacsError(usage)
        }
    }

    /// Interactive serial console in the current terminal. Ctrl-] detaches.
    private static func attachConsole(_ vm: String) -> Never {
        guard let fd = ConsoleClient.connect(vm) else {
            FileHandle.standardError.write(Data("error: no console for \(vm) (is it running?)\n".utf8))
            exit(1)
        }
        print("Proxmacs: \(vm) serial console. Press Enter for a login prompt; Ctrl-] to detach.\r")
        var original = termios()
        let isTTY = isatty(STDIN_FILENO) == 1
        if isTTY {
            tcgetattr(STDIN_FILENO, &original)
            var raw = original
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        let saved = original
        @Sendable func restoreAndExit() -> Never {
            var saved = saved
            if isTTY { tcsetattr(STDIN_FILENO, TCSANOW, &saved) }
            print("\r\nProxmacs: detached.")
            exit(0)
        }
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { restoreAndExit() }
                _ = buffer.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, n) }
            }
        }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = read(STDIN_FILENO, &buffer, buffer.count)
            if n <= 0 { restoreAndExit() }
            if buffer[0..<n].contains(0x1D) { restoreAndExit() }  // Ctrl-]
            _ = buffer.withUnsafeBytes { write(fd, $0.baseAddress, n) }
        }
    }

    /// Reads a secret from the terminal without echo.
    private static func prompt(_ message: String) -> String {
        guard let value = getpass(message) else { return "" }
        return String(cString: value)
    }

    /// Echoes task progress for long transfers.
    @MainActor
    private static func printProgress(_ state: AppState) {
        Task { @MainActor in
            var last = -1
            while true {
                if let task = state.tasks.first, task.status == .running, let progress = task.progress {
                    let percent = Int(progress * 100)
                    if percent / 5 != last / 5 { print("  \(percent)%"); last = percent }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}
