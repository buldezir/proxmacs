import SwiftUI

/// Create and revoke keys for the web API (docs/API.md).
struct APIKeysView: View {
    @State private var keys: [APIKey] = []
    @State private var lastUsed: [String: Date] = [:]
    @State private var newName = ""
    @State private var created: (name: String, secret: String)?
    @State private var copied = false
    @State private var revoking: APIKey?
    @State private var error: String?

    private var store: APIKeyStore { .shared }
    private var baseURL: String { WebServer.shared.url ?? "https://<this Mac>:8006" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Programs use the web API with a key in an Authorization header. A key can do everything the admin password can: keep it secret, and revoke it when it's no longer needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let created {
                createdBox(created)
            }

            Table(keys) {
                TableColumn("Name", value: \.name)
                TableColumn("Key") { Text($0.prefix + "…").font(.body.monospaced()) }
                    .width(min: 110, ideal: 120)
                TableColumn("Created") { Text($0.created, format: .dateTime.day().month().year()) }
                    .width(min: 90, ideal: 100)
                TableColumn("Last used") { key in
                    if let date = lastUsed[key.id] {
                        Text(date, format: .relative(presentation: .named))
                    } else {
                        Text("never").foregroundStyle(.secondary)
                    }
                }
                .width(min: 90, ideal: 110)
                TableColumn("") { key in
                    Button("Revoke", role: .destructive) { revoking = key }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
                .width(60)
            }
            .frame(minHeight: 140)
            .overlay {
                if keys.isEmpty { Text("No API keys").foregroundStyle(.secondary) }
            }

            HStack {
                TextField("Name, e.g. backup-script or home-assistant", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
                Button("Create Key", action: create)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Usage: `curl -H \"Authorization: Bearer pmx_…\" \(baseURL)/api/vms`. The API is described in docs/API.md in the Proxmacs repository; AI agents can read it at \(baseURL)/llms.txt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 620)
        .task {
            // Keys can also be created and revoked with the CLI; "last used" changes as programs call the API.
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog("Revoke the API key “\(revoking?.name ?? "")”?", isPresented: Binding(
            get: { revoking != nil }, set: { if !$0 { revoking = nil } })
        ) {
            Button("Revoke", role: .destructive) {
                if let key = revoking { revoke(key) }
            }
        } message: {
            Text("Programs using it can no longer reach the API.")
        }
    }

    private func createdBox(_ created: (name: String, secret: String)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New key “\(created.name)”: copy it now, it won't be shown again.")
                .font(.callout.weight(.medium))
            HStack {
                Text(created.secret)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(created.secret, forType: .string)
                    copied = true
                }
                Button("Done") { self.created = nil }
            }
        }
        .padding(10)
        .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func reload() {
        keys = store.load().sorted { $0.created > $1.created }
        lastUsed = store.lastUsed()
    }

    private func create() {
        do {
            let result = try store.create(name: newName)
            created = (result.key.name, result.secret)
            copied = false
            newName = ""
            error = nil
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func revoke(_ key: APIKey) {
        do {
            try store.remove(key.id)
            if created?.name == key.name { created = nil }
            error = nil
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
