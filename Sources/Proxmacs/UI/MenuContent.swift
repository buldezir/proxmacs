import SwiftUI

struct MenuContent: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    private let updater = AppUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Proxmacs").font(.headline)
                Spacer()
                Text(state.tartVersion.map { "tart \($0)" } ?? "tart not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if state.tart == nil {
                Text("Install Tart (signed build with bridged networking):\nbrew install openai/tools/tart")
                    .font(.caption)
                    .textSelection(.enabled)
            }

            ForEach(StorageKind.allCases, id: \.self) { kind in
                if !(kind == .vms ? state.vmStorageOnline : state.backupStorageOnline) {
                    Label("\(kind.label) unavailable: connect the drive with \(Storage.url(kind).path)", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let memory = state.memory {
                MemoryGauge(memory: memory, vmBytes: state.vms.filter(\.isRunning).reduce(0) { $0 + UInt64($1.memoryMB ?? 0) * 1_048_576 })
            }

            Divider()

            if state.vms.isEmpty {
                Text("No VMs yet").foregroundStyle(.secondary)
            } else {
                ForEach(state.vms) { item in
                    VMRowView(item: item)
                }
            }

            if let status = state.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let error = state.lastError {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(5).textSelection(.enabled)
                    Spacer()
                    Button { state.lastError = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                }
            }

            Divider()

            WebUISection()

            Divider()

            HStack {
                Button("New VM…") {
                    openWindow(id: "new-vm")
                    activateApp()
                }
                .disabled(state.tart == nil)
                Spacer()
                Button {
                    NSWorkspace.shared.open(Paths.support)
                } label: { Image(systemName: "folder") }
                    .help("Open data folder")
                if updater.isRelease {
                    Button(updater.menuTitle) { updater.checkForUpdates() }
                        .disabled(!updater.canCheck && updater.available == nil)
                        .help("VMs keep running while Proxmacs updates")
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .help("VMs keep running after quitting")
            }
        }
        .padding(12)
        .frame(width: 380)
    }
}

struct WebUISection: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    private var server: WebServer { WebServer.shared }
    @State private var settings = WebSettings.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Web UI").font(.subheadline.weight(.medium))
                Spacer()
                Toggle("", isOn: Binding(get: { settings.enabled }, set: { enabled in
                    settings.enabled = enabled
                    try? settings.save()
                    if enabled { server.start(state: state) } else { server.stop() }
                }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            if settings.enabled {
                if let error = server.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                } else if let url = server.url {
                    HStack(spacing: 8) {
                        Button(url) { if let link = URL(string: url) { NSWorkspace.shared.open(link) } }
                            .buttonStyle(.link)
                            .font(.caption)
                        Spacer()
                        Button("API Keys…") {
                            openWindow(id: "api-keys")
                            activateApp()
                        }
                        .font(.caption)
                        Button(WebAuth.hasPassword ? "Change Password…" : "Set Password…", action: setPassword)
                            .font(.caption)
                    }
                    if !WebAuth.hasPassword {
                        Text("Set an admin password to log in.").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .buttonStyle(.borderless)
    }

    private func setPassword() {
        let alert = NSAlert()
        alert.messageText = "Web UI admin password"
        alert.informativeText = "At least 8 characters. Used to log in at \(server.url ?? "the web UI")."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        activateApp()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try WebAuth.setPassword(field.stringValue)
            state.status = "Web UI password saved"
        } catch {
            state.lastError = error.localizedDescription
        }
    }
}

struct MemoryGauge: View {
    let memory: HostMemory
    let vmBytes: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Memory").font(.caption)
                Spacer()
                Text("\(gb(memory.used)) of \(gb(memory.total)) GB used · VMs \(gb(vmBytes)) GB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(memory.used), total: Double(max(memory.total, 1)))
                .tint(memory.pressure >= 4 ? .red : memory.pressure >= 2 ? .orange : .green)
        }
        .help("Pressure: \(memory.pressureLabel) · swap \(gb(memory.swapUsed)) GB")
    }

    private func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
}
