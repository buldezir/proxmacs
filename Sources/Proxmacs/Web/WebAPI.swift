import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// JSON API used by the browser UI (React app in web/, types in web/src/types.ts).
struct WebAPI: Sendable {
    let state: AppState
    /// The settings the server runs with (web.json may have changed since).
    var settings = WebSettings()
    var secureCookies: Bool { settings.tls }

    func register(on router: Router<WebContext>) {
        registerAuth(router)
        registerHost(router)
        registerVMs(router)
        registerBackups(router)
        registerTargets(router)
        registerJobs(router)
        registerNotifications(router)
        registerConsole(router)
        registerVNC(router)
    }

    // MARK: Auth

    private func registerAuth(_ router: Router<WebContext>) {
        let secure = secureCookies
        router.get("/api/session") { request, _ in
            let valid = await SessionStore.shared.isValid(request.cookies[SessionStore.cookieName]?.value)
            return API.json(["authenticated": valid, "passwordSet": WebAuth.hasPassword])
        }
        router.post("/api/login") { request, _ in
            await API.guarded {
                let body = try await API.body(request)
                guard WebAuth.verify(body["password"] as? String ?? "") else {
                    try await Task.sleep(for: .seconds(1))  // slow down guessing
                    return API.error(WebAuth.hasPassword ? "Wrong password" : "No admin password set (Proxmacs menu → Web UI)", status: .unauthorized)
                }
                let token = await SessionStore.shared.create()
                var response = API.noContent()
                response.setCookie(Cookie(name: SessionStore.cookieName, value: token, maxAge: Int(SessionStore.lifetime),
                                          path: "/", secure: secure, httpOnly: true, sameSite: .strict))
                return response
            }
        }
        router.post("/api/logout") { request, _ in
            await SessionStore.shared.remove(request.cookies[SessionStore.cookieName]?.value)
            var response = API.noContent()
            response.setCookie(Cookie(name: SessionStore.cookieName, value: "", maxAge: 0, path: "/", secure: secure, httpOnly: true, sameSite: .strict))
            return response
        }
    }

    // MARK: Host

    /// Where the web UI can be reached: one URL per address it listens on, the default route's interface
    /// first and loopback last.
    private static func listeningURLs(_ settings: WebSettings) async -> [[String: Any]] {
        let ports = Dictionary(await NetworkInterfaces.list().map { ($0.device, $0.name) }, uniquingKeysWith: { a, _ in a })
        let primary = await NetworkInterfaces.defaultRoute()
        func rank(_ a: HostAddress) -> Int {
            if a.device == primary { return 0 }
            if ports[a.device] != nil { return 1 }
            return a.device.hasPrefix("lo") ? 3 : 2
        }
        return NetworkInterfaces.listening(on: settings.bind)
            .enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
            .map { address in
                let host = address.ipv6 ? "[\(address.address)]" : address.address
                let name = ports[address.device] ?? (address.device.hasPrefix("lo") ? "Loopback" : nil)
                return [
                    "url": "\(settings.scheme)://\(host):\(settings.port)",
                    "address": address.address,
                    "device": address.device,
                    "name": name as Any? ?? NSNull(),
                ]
            }
    }

    private func registerHost(_ router: Router<WebContext>) {
        let state = self.state
        let settings = self.settings
        router.get("/api/host") { _, _ in
            let values = try? Paths.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            let tartVersion = await state.tartVersion
            let listening = await Self.listeningURLs(settings)
            return API.json([
                "hostname": ProcessInfo.processInfo.hostName,
                "tartVersion": tartVersion as Any? ?? NSNull(),
                "cpus": ProcessInfo.processInfo.activeProcessorCount,
                "memoryBytes": ProcessInfo.processInfo.physicalMemory,
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "diskFreeBytes": values?.volumeAvailableCapacityForImportantUsage ?? 0,
                "diskTotalBytes": values?.volumeTotalCapacity ?? 0,
                "nestedVirtualization": HostStats.supportsNestedVirtualization,
                "web": ["bind": settings.bind, "port": settings.port, "urls": listening],
            ])
        }
        router.get("/api/host/stats") { _, _ in
            let running = await MainActor.run { state.vms.filter(\.isRunning).map { $0.memoryMB ?? 0 } }
            let cpu = await state.hostCPU
            var json: [String: Any] = [
                "time": Date().ISO8601Format(),
                "cpu": cpu as Any? ?? NSNull(),
                "loadAverage": HostStats.loadAverage(),
                "runningVMs": running.count,
                "vmMemoryBytes": running.reduce(0) { $0 + UInt64($1) * 1024 * 1024 },
            ]
            if let memory = HostStats.memory() {
                json["memory"] = [
                    "total": memory.total, "used": memory.used, "app": memory.app, "wired": memory.wired,
                    "compressed": memory.compressed, "cached": memory.cached, "free": memory.free,
                    "swapUsed": memory.swapUsed, "swapTotal": memory.swapTotal, "pressure": memory.pressureLabel,
                ]
            }
            return API.json(json)
        }
        router.get("/api/host/storage") { _, _ in
            let busy = await state.storageBusy
            return API.json([
                "vms": Self.storageJSON(Storage.info(.vms)),
                "backups": Self.storageJSON(Storage.info(.backups)),
                "busy": busy?.rawValue as Any? ?? NSNull(),
                "vmsFixed": Storage.tartHomeOverridden,
                "volumes": Storage.externalVolumes().map(Self.volumeJSON),
            ])
        }
        router.put("/api/host/storage") { request, _ in
            await API.guarded {
                let body = try await API.body(request)
                guard let kind = (body["kind"] as? String).flatMap(StorageKind.init) else { throw APIError(message: "kind must be vms or backups") }
                let path = (body["path"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                let plan = try await state.planStorageChange(kind, to: path)
                let task = Self.newTaskID()
                Task { @MainActor in try? await state.changeStorage(plan, taskID: task) }
                return API.json(["task": task], status: .accepted)
            }
        }
        router.get("/api/host/sshkeys") { _, _ in
            API.json(CloudInitSeed.sshPublicKeys())
        }
        router.get("/api/interfaces") { _, _ in
            let interfaces = await NetworkInterfaces.list()
            let preferred = await NetworkInterfaces.defaultRoute()
            return API.json(interfaces.map { ["device": $0.device, "name": $0.name, "default": $0.device == preferred] })
        }
        router.get("/api/images") { _, _ in
            let progress = ImageDownloads.shared.progress()
            return API.json(ImageStore.entries().map { image -> [String: Any] in
                let download = progress[image.id]
                return [
                    "id": image.id, "name": image.name, "distro": image.catalog?.distro as Any? ?? NSNull(),
                    "user": image.catalog?.user as Any? ?? NSNull(), "url": image.catalog?.page.absoluteString as Any? ?? NSNull(),
                    "imported": image.catalog == nil, "cached": image.cached,
                    "sizeBytes": image.virtualBytes as Any? ?? NSNull(), "diskBytes": image.diskBytes as Any? ?? NSNull(),
                    "downloading": download.map { ["message": $0.message, "progress": $0.fraction as Any? ?? NSNull()] } as Any? ?? NSNull(),
                ]
            })
        }
        router.post("/api/images/:id/download") { _, context in
            await API.guarded {
                guard let image = context.parameters.get("id").flatMap(ImageCatalog.find) else { throw APIError.notFound("Image") }
                let task = Self.newTaskID()
                Task { @MainActor in try? await state.downloadImage(image, taskID: task) }
                return API.json(["task": task], status: .accepted)
            }
        }
        router.delete("/api/images/:id") { _, context in
            await API.guarded {
                try await state.deleteImage(context.parameters.get("id") ?? "")
                return API.noContent()
            }
        }
        router.get("/api/tasks") { _, _ in
            let tasks = await state.tasks
            return API.json(tasks.map { task -> [String: Any] in
                [
                    "id": task.id, "vm": task.vm as Any? ?? NSNull(), "title": task.title, "status": task.status.rawValue,
                    "message": task.message as Any? ?? NSNull(), "progress": task.progress as Any? ?? NSNull(),
                    "started": task.started.ISO8601Format(), "finished": task.finished?.ISO8601Format() as Any? ?? NSNull(),
                ]
            })
        }
    }

    // MARK: VMs

    static func sampleJSON(_ sample: VMSample) -> [String: Any] {
        func value(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }
        return ["t": Int(sample.time.timeIntervalSince1970 * 1000), "cpu": sample.cpu, "memory": sample.memory,
                "guestUsed": value(sample.guestUsed), "guestTotal": value(sample.guestTotal),
                "diskRead": sample.diskRead, "diskWrite": sample.diskWrite, "netIn": value(sample.netIn), "netOut": value(sample.netOut)]
    }

    @MainActor
    static func vmJSON(_ item: VMItem, state: AppState) -> [String: Any] {
        let activity = state.activity[item.name]
        var network: [String: Any] = ["mode": "nat", "interface": NSNull()]
        if case .bridged(let iface) = item.meta.network { network = ["mode": "bridged", "interface": iface] }
        let config = item.meta.effectiveCloudInit
        let password = !config.managePassword && config.passwordHash == nil ? "unknown" : (config.passwordHash == nil ? "none" : "set")
        let cloudInit: [String: Any] = [
            "user": config.user, "password": password, "sshKeys": config.sshKeys, "legacy": item.meta.cloudInit == nil,
            "network": ["dhcp": config.network.dhcp, "address": config.network.address as Any? ?? NSNull(),
                        "gateway": config.network.gateway as Any? ?? NSNull(), "dns": config.network.dns],
        ]
        return [
            "cloudInit": cloudInit, "seedPending": item.meta.seedPending, "image": item.meta.image as Any? ?? NSNull(),
            "hasSeed": FileManager.default.fileExists(atPath: Paths.seedISO(item.name).path),
            "name": item.name, "state": item.state, "ip": item.ip as Any? ?? NSNull(), "network": network,
            "cpus": item.cpus as Any? ?? NSNull(), "memoryMB": item.memoryMB as Any? ?? NSNull(), "diskGB": item.diskGB as Any? ?? NSNull(),
            "autostart": item.meta.autostart, "activity": activity as Any? ?? NSNull(),
            "backup": ["keep": item.meta.backup.keep, "keepDaily": item.meta.backup.keepDaily, "keepWeekly": item.meta.backup.keepWeekly,
                       "keepMonthly": item.meta.backup.keepMonthly, "keepYearly": item.meta.backup.keepYearly],
            "offsite": ["targets": item.meta.offsite.targets, "auto": item.meta.offsite.auto],
            "template": item.meta.template, "tags": item.meta.tags, "notes": item.meta.notes,
            "startOrder": item.meta.startOrder as Any? ?? NSNull(), "startDelay": item.meta.startDelay,
            "nested": item.meta.nested,
            "disks": item.meta.disks.map { disk -> [String: Any] in
                let url = Paths.tartVMDir(item.name).appending(path: disk.file)
                return ["file": disk.file, "sizeGB": AppState.diskGB(url), "usedBytes": FileCopy.allocatedSize(of: url), "backup": disk.backup]
            },
            "shares": item.meta.shares.map { ["name": $0.name, "path": $0.path, "readOnly": $0.readOnly] },
            "stats": Self.statsJSON(item, state: state),
        ]
    }

    @MainActor
    private static func statsJSON(_ item: VMItem, state: AppState) -> Any {
        guard item.isRunning else { return NSNull() }
        var json: [String: Any] = [:]
        if let sample = state.metrics.latest[item.name] { json = sampleJSON(sample) }
        if let started = state.metrics.started[item.name] { json["uptime"] = Int(Date().timeIntervalSince(started)) }
        return json.isEmpty ? NSNull() : json
    }

    private func registerVMs(_ router: Router<WebContext>) {
        let state = self.state
        router.get("/api/vms") { _, _ in
            await MainActor.run { API.json(state.vms.map { Self.vmJSON($0, state: state) }) }
        }

        router.post("/api/vms") { request, _ in
            await API.guarded {
                let body = try await API.body(request)
                guard let name = body["name"] as? String else { throw APIError(message: "name is required") }
                let mode = await Self.networkMode(body["network"] as? [String: Any]) ?? .nat
                let imageID = body["image"] as? String ?? ImageCatalog.defaultID
                guard let image = ImageSource.named(imageID) else { throw APIError(message: "No image \(imageID)") }
                let vmRequest = NewVMRequest(
                    name: name, cpus: body["cpus"] as? Int ?? 2, memoryMB: body["memoryMB"] as? Int ?? 2048,
                    diskGB: body["diskGB"] as? Int ?? 20, network: mode, image: image,
                    password: body["password"] as? String ?? "", autostart: body["autostart"] as? Bool ?? false,
                    startNow: body["startNow"] as? Bool ?? true,
                    user: body["user"] as? String ?? "debian",
                    sshKeys: (body["sshKeys"] as? [Any]).map(Self.keys),
                    guestNetwork: Self.guestNetwork(body["ipv4"] as? [String: Any])
                )
                try await state.validateNewVM(name)
                try vmRequest.cloudInit.validate()
                let task = Self.newTaskID()
                Task { @MainActor in try? await state.create(vmRequest, taskID: task) }
                return API.json(["task": task], status: .accepted)
            }
        }

        // stop = shut down (forced after 30 s), poweroff = turn off at once, reset = poweroff + start.
        for action in ["start", "stop", "poweroff", "reboot", "reset", "backup"] {
            router.post("/api/vms/:name/\(action)") { request, context in
                await API.guarded {
                    let name = try await Self.requireVM(state, context)
                    // backup: {"target": id} backs up straight to an offsite target instead of local backups.
                    let target = action == "backup" ? try Self.backupTarget(try await API.body(request)["target"]) : nil
                    let task = Self.newTaskID()
                    Task { @MainActor in
                        switch action {
                        case "start": await state.start(name, taskID: task)
                        case "stop": await state.stop(name, taskID: task)
                        case "poweroff": await state.stop(name, force: true, taskID: task)
                        case "reboot": await state.reboot(name, taskID: task)
                        case "reset": await state.reboot(name, force: true, taskID: task)
                        default: await state.backup(name, to: target, taskID: task)
                        }
                    }
                    return API.json(["task": task], status: .accepted)
                }
            }
        }

        router.post("/api/vms/:name/clone") { request, context in
            await API.guarded {
                let source = try await Self.requireVM(state, context)
                let body = try await API.body(request)
                guard let name = body["name"] as? String else { throw APIError(message: "name is required") }
                try await state.validateNewVM(name)
                let network = (body["ipv4"] as? [String: Any]).map(Self.guestNetwork)
                let start = body["start"] as? Bool ?? false
                let task = Self.newTaskID()
                Task { @MainActor in try? await state.clone(source, to: name, start: start, network: network, taskID: task) }
                return API.json(["task": task], status: .accepted)
            }
        }

        router.post("/api/vms/:name/template") { request, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                let body = try await API.body(request)
                try await state.setTemplate(name, body["template"] as? Bool ?? true)
                return try await Self.currentVM(state, name)
            }
        }

        router.post("/api/vms/:name/disks") { request, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                let body = try await API.body(request)
                guard let size = body["sizeGB"] as? Int else { throw APIError(message: "sizeGB is required") }
                _ = try await state.addDisk(name, sizeGB: size)
                return try await Self.currentVM(state, name)
            }
        }
        router.put("/api/vms/:name/disks/:file") { request, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                let file = try Self.param(context, "file")
                let body = try await API.body(request)
                if let size = body["sizeGB"] as? Int { try await state.resizeDisk(name, file: file, sizeGB: size) }
                if let backup = body["backup"] as? Bool { try await state.setDiskBackup(name, file: file, backup: backup) }
                return try await Self.currentVM(state, name)
            }
        }
        router.delete("/api/vms/:name/disks/:file") { _, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                try await state.removeDisk(name, file: try Self.param(context, "file"))
                return try await Self.currentVM(state, name)
            }
        }
        router.post("/api/vms/:name/shares") { request, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                let body = try await API.body(request)
                guard let share = body["name"] as? String, let path = body["path"] as? String else {
                    throw APIError(message: "name and path are required")
                }
                try await state.addShare(name, SharedFolder(name: share, path: path, readOnly: body["readOnly"] as? Bool ?? false))
                return try await Self.currentVM(state, name)
            }
        }
        router.delete("/api/vms/:name/shares/:share") { _, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                try await state.removeShare(name, name: try Self.param(context, "share"))
                return try await Self.currentVM(state, name)
            }
        }

        router.get("/api/vms/:name/metrics") { request, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                let range = request.uri.queryParameters.get("range").flatMap(MetricsRange.init) ?? .hour
                let samples = await MainActor.run { state.metrics.history(name, range: range) }
                return API.json(["range": range.rawValue, "step": range.step, "samples": samples.map(Self.sampleJSON)])
            }
        }

        router.get("/api/vms/:name/guest") { request, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                let info = try await state.guestInfo(name, refresh: request.uri.queryParameters.get("refresh") == "1")
                return API.json([
                    "os": info.os as Any? ?? NSNull(), "kernel": info.kernel as Any? ?? NSNull(),
                    "hostname": info.hostname as Any? ?? NSNull(), "uptime": info.uptime.map { Int($0) } as Any? ?? NSNull(),
                    "updated": info.updated.ISO8601Format(),
                    "interfaces": info.interfaces.map { ["name": $0.name, "mac": $0.mac as Any? ?? NSNull(), "addresses": $0.addresses] },
                    "filesystems": info.filesystems.map {
                        ["device": $0.device, "type": $0.type, "mount": $0.mount, "sizeBytes": $0.size, "usedBytes": $0.used]
                    },
                ])
            }
        }

        router.delete("/api/vms/:name") { _, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                let task = Self.newTaskID()
                Task { @MainActor in await state.delete(name, taskID: task) }
                return API.json(["task": task], status: .accepted)
            }
        }

        router.put("/api/vms/:name/hardware") { request, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                let body = try await API.body(request)
                let change = HardwareChange(cpus: body["cpus"] as? Int, memoryMB: body["memoryMB"] as? Int, diskGB: body["diskGB"] as? Int,
                                            network: await Self.networkMode(body["network"] as? [String: Any]),
                                            nested: body["nested"] as? Bool)
                try await state.editHardware(name, change)
                return try await Self.currentVM(state, name)
            }
        }

        router.put("/api/vms/:name/cloudinit") { request, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                let body = try await API.body(request)
                let password: PasswordChange = if let plain = body["password"] as? String, !plain.isEmpty {
                    .set(plain)
                } else if body["removePassword"] as? Bool == true {
                    .remove
                } else {
                    .keep
                }
                guard let user = body["user"] as? String else { throw APIError(message: "user is required") }
                try await state.editCloudInit(name, user: user, password: password, sshKeys: Self.keys(body["sshKeys"] as? [Any] ?? []),
                                              network: Self.guestNetwork(body["ipv4"] as? [String: Any]))
                return try await Self.currentVM(state, name)
            }
        }

        router.patch("/api/vms/:name") { request, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                let body = try await API.body(request)
                let targetIDs = Set(TargetStore.load().map(\.id))
                let tags = try (body["tags"] as? [Any]).map(Self.tags)
                if let notes = body["notes"] as? String, notes.utf8.count > 16_384 { throw APIError(message: "Notes are too long") }
                if let order = body["startOrder"] as? Int, !(0...9999).contains(order) { throw APIError(message: "Start order must be 0–9999") }
                if let delay = body["startDelay"] as? Int, !(0...3600).contains(delay) { throw APIError(message: "Startup delay must be 0–3600 s") }
                return try await MainActor.run {
                    if body["autostart"] as? Bool == true, VMMeta.load(name)?.template == true {
                        throw APIError(message: "Templates can't start on login")
                    }
                    try state.updateMeta(name) { meta in
                        if let autostart = body["autostart"] as? Bool { meta.autostart = autostart }
                        if let backup = body["backup"] as? [String: Any] {
                            if let keep = backup["keep"] as? Int { meta.backup.keep = min(max(keep, 0), 9999) }
                            if let keep = backup["keepDaily"] as? Int { meta.backup.keepDaily = min(max(keep, 0), 9999) }
                            if let keep = backup["keepWeekly"] as? Int { meta.backup.keepWeekly = min(max(keep, 0), 9999) }
                            if let keep = backup["keepMonthly"] as? Int { meta.backup.keepMonthly = min(max(keep, 0), 9999) }
                            if let keep = backup["keepYearly"] as? Int { meta.backup.keepYearly = min(max(keep, 0), 9999) }
                        }
                        if let tags { meta.tags = tags }
                        if let notes = body["notes"] as? String { meta.notes = notes }
                        if body.keys.contains("startOrder") { meta.startOrder = body["startOrder"] as? Int }
                        if let delay = body["startDelay"] as? Int { meta.startDelay = delay }
                        if let offsite = body["offsite"] as? [String: Any] {
                            if let targets = offsite["targets"] as? [String] { meta.offsite.targets = targets.filter(targetIDs.contains) }
                            if let auto = offsite["auto"] as? Bool { meta.offsite.auto = auto }
                        }
                    }
                    guard let item = state.vms.first(where: { $0.name == name }) else { throw APIError.notFound("VM \(name)") }
                    return API.json(Self.vmJSON(item, state: state))
                }
            }
        }
    }

    // MARK: Local backups

    private func registerBackups(_ router: Router<WebContext>) {
        let state = self.state
        router.get("/api/vms/:name/backups") { _, context in
            await API.guarded {
                let name = try Self.param(context, "name")
                try Storage.require(.backups)
                return API.json(BackupManager.list(name).map { backup -> [String: Any] in
                    ["id": backup.name, "date": backup.record.date.ISO8601Format(), "consistent": backup.record.consistent,
                     "source": backup.record.source as Any? ?? NSNull()]
                })
            }
        }
        router.post("/api/vms/:name/backups/:id/restore") { _, context in
            await API.guarded {
                let (name, backup) = try Self.backup(context)
                let task = Self.newTaskID()
                Task { @MainActor in await state.restore(name, backup, taskID: task) }
                return API.json(["task": task], status: .accepted)
            }
        }
        router.post("/api/vms/:name/backups/:id/push") { request, context in
            await API.guarded {
                let (name, backup) = try Self.backup(context)
                let body = try await API.body(request)
                guard let target = (body["target"] as? String).flatMap(TargetStore.target) else { throw APIError.notFound("target") }
                let task = Self.newTaskID()
                Task { @MainActor in await state.push(name, backup: backup, targetID: target.id, taskID: task) }
                return API.json(["task": task], status: .accepted)
            }
        }
        router.delete("/api/vms/:name/backups/:id") { _, context in
            await API.guarded {
                let (_, backup) = try Self.backup(context)
                try BackupManager.delete(backup)
                return API.noContent()
            }
        }
    }

    // MARK: Offsite targets

    static func targetJSON(_ target: OffsiteTarget) -> [String: Any] {
        var json: [String: Any] = ["id": target.id, "name": target.name, "kind": target.kind.rawValue,
                                   "location": target.location, "keep": target.keep, "smb": NSNull(), "pbs": NSNull()]
        if let smb = target.smb { json["smb"] = ["url": smb.url] }
        if let pbs = target.pbs {
            json["pbs"] = ["host": pbs.host, "port": pbs.port, "datastore": pbs.datastore, "namespace": pbs.namespace as Any? ?? NSNull(),
                           "authId": pbs.authId, "fingerprint": pbs.fingerprint as Any? ?? NSNull()]
        }
        return json
    }

    private func registerTargets(_ router: Router<WebContext>) {
        let state = self.state
        router.get("/api/targets") { _, _ in
            API.json(TargetStore.load().map(Self.targetJSON))
        }
        router.post("/api/targets") { request, _ in
            await API.guarded {
                let body = try await API.body(request)
                let (target, secret) = try Self.parseTarget(body)
                try await MainActor.run { try state.addTarget(target, secret: secret) }
                return API.json(Self.targetJSON(target), status: .created)
            }
        }
        router.delete("/api/targets/:id") { _, context in
            await API.guarded {
                let id = try Self.param(context, "id")
                try await MainActor.run { try state.removeTarget(id) }
                return API.noContent()
            }
        }
        router.post("/api/targets/:id/test") { _, context in
            await API.guarded {
                let result = await state.testTarget(try Self.param(context, "id"))
                return API.json(["ok": result.ok, "message": result.message])
            }
        }
        router.get("/api/targets/:id/snapshots") { request, context in
            await API.guarded {
                let id = try Self.param(context, "id")
                guard let vm = request.uri.queryParameters.get("vm"), !vm.isEmpty else { throw APIError(message: "vm is required") }
                let snapshots = try await state.remoteSnapshots(targetID: id, vm: vm)
                return API.json(snapshots.map { ["vm": $0.vm, "time": $0.time.ISO8601Format(), "id": $0.id] })
            }
        }
        router.post("/api/targets/:id/verify") { request, context in
            await API.guarded {
                let id = try Self.param(context, "id")
                let body = try await API.body(request)
                guard let vm = body["vm"] as? String, let snapshot = body["id"] as? String else { throw APIError(message: "vm and id are required") }
                let task = Self.newTaskID()
                Task { @MainActor in await state.verify(vm, snapshotID: snapshot, targetID: id, taskID: task) }
                return API.json(["task": task], status: .accepted)
            }
        }
        router.post("/api/targets/:id/pull") { request, context in
            await API.guarded {
                let id = try Self.param(context, "id")
                let body = try await API.body(request)
                guard let vm = body["vm"] as? String, let snapshot = body["id"] as? String else { throw APIError(message: "vm and id are required") }
                let exists = VMMeta.load(vm) != nil
                let task = Self.newTaskID()
                Task { @MainActor in await state.pull(vm, snapshotID: snapshot, targetID: id, taskID: task) }
                return API.json(["task": task,
                                 "message": exists ? "Pulling into local backups of \(vm)" : "Pulling and recreating \(vm)"],
                                status: .accepted)
            }
        }
    }

    static func parseTarget(_ body: [String: Any]) throws -> (OffsiteTarget, String?) {
        guard let name = (body["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw APIError(message: "name is required")
        }
        let keep = max(body["keep"] as? Int ?? 7, 1)
        switch body["kind"] as? String {
        case "smb":
            guard let smb = body["smb"] as? [String: Any], let url = smb["url"] as? String else { throw APIError(message: "smb.url is required") }
            _ = try SMBLocation(parsing: url)
            return (OffsiteTarget(name: name, kind: .smb, keep: keep, smb: SMBSettings(url: url)), smb["password"] as? String)
        case "pbs":
            guard let pbs = body["pbs"] as? [String: Any], let host = pbs["host"] as? String, let datastore = pbs["datastore"] as? String,
                  let authId = pbs["authId"] as? String else { throw APIError(message: "pbs.host, pbs.datastore and pbs.authId are required") }
            guard authId.contains("!") else { throw APIError(message: "authId must be an API token id like user@pbs!tokenname") }
            let namespace = (pbs["namespace"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let fingerprint = (pbs["fingerprint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let settings = PBSSettings(host: host, port: pbs["port"] as? Int ?? 8007, datastore: datastore,
                                       namespace: namespace, authId: authId, fingerprint: fingerprint)
            return (OffsiteTarget(name: name, kind: .pbs, keep: keep, pbs: settings), pbs["secret"] as? String)
        default:
            throw APIError(message: "kind must be smb or pbs")
        }
    }

    // MARK: Backup jobs

    static func jobJSON(_ job: BackupJob, running: Bool) -> [String: Any] {
        ["id": job.id, "enabled": job.enabled, "comment": job.comment, "title": job.title, "days": job.days,
         "hour": job.hour, "minute": job.minute, "selection": job.selection.rawValue, "vms": job.vms,
         "notify": job.notify.rawValue, "schedule": job.scheduleLabel, "running": running,
         "target": job.target as Any? ?? NSNull(),
         "targetName": job.target.flatMap { TargetStore.target($0)?.name } as Any? ?? NSNull(),
         "nextRun": job.nextRun(after: Date())?.ISO8601Format() as Any? ?? NSNull(),
         "lastRun": job.lastRun?.ISO8601Format() as Any? ?? NSNull(), "lastOK": job.lastOK as Any? ?? NSNull(),
         "lastMessage": job.lastMessage as Any? ?? NSNull()]
    }

    static func parseJob(_ body: [String: Any], into job: inout BackupJob) throws {
        let scheduleBefore = (job.days, job.hour, job.minute, job.enabled)
        if let enabled = body["enabled"] as? Bool { job.enabled = enabled }
        if let comment = body["comment"] as? String { job.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let days = body["days"] as? [Int] { job.days = Array(Set(days)).sorted() }
        if let hour = body["hour"] as? Int { job.hour = hour }
        if let minute = body["minute"] as? Int { job.minute = minute }
        if let selection = body["selection"] as? String {
            guard let value = BackupJob.Selection(rawValue: selection) else { throw APIError(message: "selection must be all, include or exclude") }
            job.selection = value
        }
        if let vms = body["vms"] as? [String] { job.vms = vms }
        if body.keys.contains("target") { job.target = try backupTarget(body["target"]) }
        if let notify = body["notify"] as? String {
            guard let value = NotifyWhen(rawValue: notify) else { throw APIError(message: "notify must be never, failure or always") }
            job.notify = value
        }
        // A changed schedule starts counting from now, so it doesn't fire for a time already passed.
        if scheduleBefore != (job.days, job.hour, job.minute, job.enabled) { job.since = Date() }
        try job.validate()
    }

    private func registerJobs(_ router: Router<WebContext>) {
        let state = self.state
        router.get("/api/jobs") { _, _ in
            let running = await state.runningJobs
            return API.json(JobStore.load().map { Self.jobJSON($0, running: running.contains($0.id)) })
        }
        router.post("/api/jobs") { request, _ in
            await API.guarded {
                var job = BackupJob()
                try Self.parseJob(try await API.body(request), into: &job)
                try JobStore.upsert(job)
                return API.json(Self.jobJSON(job, running: false), status: .created)
            }
        }
        router.put("/api/jobs/:id") { request, context in
            await API.guarded {
                guard var job = JobStore.job(try Self.param(context, "id")) else { throw APIError.notFound("job") }
                try Self.parseJob(try await API.body(request), into: &job)
                try JobStore.upsert(job)
                let running = await state.runningJobs.contains(job.id)
                return API.json(Self.jobJSON(job, running: running))
            }
        }
        router.delete("/api/jobs/:id") { _, context in
            await API.guarded {
                try JobStore.remove(try Self.param(context, "id"))
                return API.noContent()
            }
        }
        router.post("/api/jobs/:id/run") { _, context in
            await API.guarded {
                guard let job = JobStore.job(try Self.param(context, "id")) else { throw APIError.notFound("job") }
                if await state.runningJobs.contains(job.id) { throw APIError(message: "\(job.title) is already running") }
                let task = Self.newTaskID()
                Task { @MainActor in await state.runJob(job.id, taskID: task) }
                return API.json(["task": task], status: .accepted)
            }
        }
    }

    // MARK: Notifications

    static func notificationJSON(_ target: NotificationTarget) -> [String: Any] {
        ["id": target.id, "name": target.name, "enabled": target.enabled, "format": target.format.rawValue,
         "host": target.host as Any? ?? NSNull(), "location": target.location]
    }

    /// Applies the request to `target`; returns the new webhook URL (nil = unchanged).
    static func parseNotification(_ body: [String: Any], into target: inout NotificationTarget) throws -> String? {
        if let name = body["name"] as? String { target.name = name.trimmingCharacters(in: .whitespaces) }
        if let enabled = body["enabled"] as? Bool { target.enabled = enabled }
        if let format = body["format"] as? String {
            guard let value = NotificationTarget.Format(rawValue: format) else { throw APIError(message: "format must be json, discord, slack or ntfy") }
            target.format = value
        }
        return (body["url"] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func registerNotifications(_ router: Router<WebContext>) {
        router.get("/api/notifications") { _, _ in
            API.json(NotificationStore.load().map(Self.notificationJSON))
        }
        router.post("/api/notifications") { request, _ in
            await API.guarded {
                var target = NotificationTarget(name: "")
                let url = try Self.parseNotification(try await API.body(request), into: &target)
                try NotificationStore.upsert(target, url: url)
                return API.json(Self.notificationJSON(NotificationStore.target(target.id) ?? target), status: .created)
            }
        }
        router.put("/api/notifications/:id") { request, context in
            await API.guarded {
                guard var target = NotificationStore.target(try Self.param(context, "id")) else { throw APIError.notFound("notification target") }
                let url = try Self.parseNotification(try await API.body(request), into: &target)
                try NotificationStore.upsert(target, url: url)
                return API.json(Self.notificationJSON(NotificationStore.target(target.id) ?? target))
            }
        }
        router.delete("/api/notifications/:id") { _, context in
            await API.guarded {
                try NotificationStore.remove(try Self.param(context, "id"))
                return API.noContent()
            }
        }
        router.post("/api/notifications/:id/test") { _, context in
            await API.guarded {
                guard let target = NotificationStore.target(try Self.param(context, "id")) else { throw APIError.notFound("notification target") }
                do {
                    try await Notifier.send(target, title: "Proxmacs test notification",
                                            message: "Notifications from \(ProcessInfo.processInfo.hostName) reach this target.", failed: false)
                    return API.json(["ok": true, "message": "Sent a test notification to \(target.name)"])
                } catch {
                    return API.json(["ok": false, "message": error.localizedDescription])
                }
            }
        }
    }

    // MARK: Console

    private func registerConsole(_ router: Router<WebContext>) {
        router.ws("/api/vms/:name/console") { _, context in
            guard let name = context.parameters.get("name"),
                  FileManager.default.fileExists(atPath: VMRunner.socketPath(name).path) else { return .dontUpgrade }
            return .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            guard let name = context.requestContext.parameters.get("name") else { return }
            try await ConsoleBridge.run(vm: name, inbound: inbound, outbound: outbound)
        }
    }

    // MARK: VNC (browser display via noVNC)

    private func registerVNC(_ router: Router<WebContext>) {
        // The guest macOS account that signs in to Screen Sharing. GET is the one endpoint
        // that hands a stored secret back out: noVNC answers the RFB handshake client-side,
        // so auto-fill needs it. Browser sessions only: a script's API key has no use for a
        // guest password. AuthMiddleware takes any Authorization header as an API key.
        router.get("/api/vms/:name/vnc/credentials") { request, context in
            await API.guarded {
                guard request.headers[.authorization] == nil else {
                    throw APIError(message: "API keys can't read saved Screen Sharing credentials; sign in to the web UI",
                                   status: .forbidden)
                }
                let name = try await Self.requireVM(state, context)
                let credentials = VNCCredentials.load(name)
                let user: Any = credentials?.username ?? NSNull()
                let pass: Any = credentials?.password ?? NSNull()
                return API.json(["username": user, "password": pass])
            }
        }
        router.put("/api/vms/:name/vnc/credentials") { request, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                let body = try await API.body(request)
                guard let username = body["username"] as? String, !username.isEmpty,
                      let password = body["password"] as? String, !password.isEmpty else {
                    throw APIError(message: "username and password are required")
                }
                try VNCCredentials.save(name, username: username, password: password)
                return API.noContent()
            }
        }
        router.delete("/api/vms/:name/vnc/credentials") { _, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                try VNCCredentials.clear(name)
                return API.noContent()
            }
        }
        // Changes the guest's settings, so only on request: the Display tab offers it when
        // Screen Sharing is off or turns down a sign-in.
        router.post("/api/vms/:name/vnc/setup") { _, context in
            await API.guarded {
                let name = try await Self.requireVM(state, context)
                guard ScreenSharingSetup.isMacOS(name) else {
                    throw APIError(message: "Screen Sharing setup is for macOS guests. Start a VNC server on port 5900 in \(name).")
                }
                guard await state.isRunning(name) else {
                    throw APIError(message: "\(name) is not running. Start it, then try again.")
                }
                let outcome = try await ScreenSharingSetup.shared.setUp(name)
                return API.json(["changed": outcome.changed, "message": outcome.message])
            }
        }
        router.ws("/api/vms/:name/vnc/ws") { _, context in
            guard context.parameters.get("name") != nil else { return .dontUpgrade }
            return .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            guard let name = context.requestContext.parameters.get("name") else { return }
            try await VNCBridge.run(state: state, vm: name, inbound: inbound, outbound: outbound)
        }
    }

    // MARK: Helpers

    static func newTaskID() -> String { UUID().uuidString.lowercased() }

    static func storageJSON(_ info: StorageInfo) -> [String: Any] {
        ["path": info.path, "default": info.isDefault, "available": info.available,
         "volume": info.volume.map(volumeJSON) as Any? ?? NSNull()]
    }

    static func volumeJSON(_ volume: VolumeInfo) -> [String: Any] {
        ["path": volume.path, "name": volume.name, "fileSystem": volume.fileSystem, "internal": volume.isInternal,
         "ejectable": volume.ejectable, "freeBytes": volume.freeBytes, "totalBytes": volume.totalBytes]
    }

    static func param(_ context: WebContext, _ name: String) throws -> String {
        guard let value = context.parameters.get(name), !value.isEmpty else { throw APIError(message: "missing \(name)") }
        return value
    }

    static func currentVM(_ state: AppState, _ name: String) async throws -> Response {
        try await MainActor.run {
            guard let item = state.vms.first(where: { $0.name == name }) else { throw APIError.notFound("VM \(name)") }
            return API.json(vmJSON(item, state: state))
        }
    }

    static func networkMode(_ json: [String: Any]?) async -> NetworkMode? {
        switch json?["mode"] as? String {
        case "nat": return .nat
        case "bridged":
            let iface = (json?["interface"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let iface { return .bridged(interface: iface) }
            return .bridged(interface: await NetworkInterfaces.defaultRoute() ?? "en0")
        default: return nil
        }
    }

    static func guestNetwork(_ json: [String: Any]?) -> GuestNetwork {
        guard let json, json["dhcp"] as? Bool == false else { return GuestNetwork() }
        let trimmed = { (value: Any?) -> String? in
            (value as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        return GuestNetwork(dhcp: false, address: trimmed(json["address"]), gateway: trimmed(json["gateway"]),
                            dns: ((json["dns"] as? [Any]) ?? []).compactMap(trimmed))
    }

    /// A backup destination from a request: null, "" or "local" = local backups, else an offsite target id.
    static func backupTarget(_ value: Any?) throws -> String? {
        guard let id = value as? String, !id.isEmpty, id != "local" else { return nil }
        guard let target = TargetStore.target(id) else { throw APIError.notFound("backup target") }
        return target.id
    }

    static func tags(_ list: [Any]) throws -> [String] {
        var result: [String] = []
        for case let tag as String in list {
            let tag = tag.trimmingCharacters(in: .whitespaces).lowercased()
            if tag.isEmpty || result.contains(tag) { continue }
            guard VMMeta.isValidTag(tag) else { throw APIError(message: "Tags are lowercase letters, digits and . _ + - (up to 32)") }
            result.append(tag)
        }
        return result
    }

    static func keys(_ list: [Any]) -> [String] {
        list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func requireVM(_ state: AppState, _ context: WebContext) async throws -> String {
        let name = try param(context, "name")
        guard VMMeta.load(name) != nil else { throw APIError.notFound("VM \(name)") }
        return name
    }

    static func backup(_ context: WebContext) throws -> (String, BackupInfo) {
        let name = try param(context, "name")
        let id = try param(context, "id")
        guard let backup = BackupManager.list(name).first(where: { $0.name == id }) else { throw APIError.notFound("backup \(id)") }
        return (name, backup)
    }
}

/// Bridges a VM console socket (served by VMRunner) to a WebSocket.
enum ConsoleBridge {
    static func run(vm: String, inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter) async throws {
        guard let fd = ConsoleClient.connect(vm) else {
            try await outbound.close(.unexpectedServerError, reason: "console not available")
            return
        }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let scrollback = ConsoleClient.scrollback(vm)
        if !scrollback.isEmpty { try await outbound.write(.binary(ByteBuffer(bytes: scrollback))) }

        let output = AsyncStream<Data> { continuation in
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
            source.setEventHandler {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(fd, &buffer, buffer.count)
                    if n > 0 {
                        continuation.yield(Data(buffer[0..<n]))
                    } else {
                        if n == 0 || (errno != EAGAIN && errno != EINTR) { continuation.finish() }
                        break
                    }
                }
            }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await data in output {
                    try await outbound.write(.binary(ByteBuffer(bytes: data)))
                }
            }
            group.addTask {
                for try await message in inbound.messages(maxSize: 1 << 16) {
                    let bytes: [UInt8] = switch message {
                    case .text(let text): Array(text.utf8)
                    case .binary(let buffer): Array(buffer.readableBytesView)
                    }
                    writeAll(fd, bytes)
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n > 0 { offset += n } else if errno == EAGAIN || errno == EINTR { usleep(1000) } else { return }
        }
    }
}
