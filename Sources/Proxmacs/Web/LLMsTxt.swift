import Foundation
import Hummingbird
import NIOCore

/// `/llms.txt` (llmstxt.org): how an AI agent should use the web API, then the API reference (docs/API.md), so an
/// agent given this server's address learns all of it in one request. Like the web UI's own files, it needs no login.
enum LLMsTxt {
    static func response() -> Response {
        Response(status: .ok, headers: [.contentType: "text/plain; charset=utf-8"], body: .init(byteBuffer: ByteBuffer(string: text)))
    }

    static let text: String = {
        guard let reference = apiReference(), reference.hasPrefix("# ") else {
            return guide + "\nThe API reference is docs/API.md in the Proxmacs repository: https://github.com/buldezir/proxmacs/blob/main/docs/API.md\n"
        }
        // Under this file's title instead of its own.
        return guide + "\n## API reference" + reference.drop { $0 != "\n" }
    }()

    /// Copied into the app by scripts/build-app.sh; in development, read from the source tree.
    private static func apiReference() -> String? {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/API.md")
        return [Bundle.main.resourceURL?.appending(path: "API.md"), source].lazy
            .compactMap { $0.flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
            .first
    }

    private static let guide = #"""
        # Proxmacs

        > Proxmacs runs Linux VMs on an Apple Silicon Mac, with Tart. This server's JSON API, the one its web UI uses,
        > creates, starts, stops, clones, backs up and monitors them. Below: how an AI agent should use the API, then
        > the full reference.

        ## Using the API as an agent

        - **Base URL**: the scheme, host and port you fetched this file from (`https://<mac>:8006` by default). Every
          endpoint is under `/api/`. This file and the web UI need no login; the API does.
        - **Authentication**: send `Authorization: Bearer pmx_…` with every request. Ask the user for an API key: they
          create one in the menubar (Proxmacs menu → Web UI → API Keys…), or on the Mac with
          `Proxmacs cli api-key-add <name>`. Don't ask for the admin password or use `/api/login`, which are for
          browsers. A key can do everything the admin password can: keep it in an environment variable, out of files
          and output.
        - **TLS**: the certificate is self-signed unless a reverse proxy serves Proxmacs. On the Mac, use
          `curl --cacert ~/Library/Application\ Support/Proxmacs/web/cert.pem`; elsewhere, `curl -k` (see TLS below).
        - **Long operations are tasks.** Creating, starting, stopping, cloning, backing up, restoring and deleting
          answer `202 {"task": "<id>"}` at once. That means started, not done: poll `GET /api/tasks` every few seconds
          until the task with that id (it can take a moment to appear) has `status` `ok` or `error`, and read its
          `message`, before you report the result or take the next step.
        - **Errors** are `{"error": "…"}` with a 4xx status, written for the user: pass them on rather than guess
          around them.
        - **Look before you act.** `GET /api/vms` gives each VM's `state` (`running`, `stopped`, or `offline` while
          its drive is unplugged) and `activity` (an operation in progress, or null: wait for it to clear). Hardware
          changes, extra disks, shared folders and restores need the VM stopped. Templates can't be started, only
          cloned.
        - **Partial or whole.** `PATCH /api/vms/:name` and `PUT /api/vms/:name/hardware` change only the fields you
          send. `PUT /api/vms/:name/cloudinit` replaces all of cloud-init: send `user`, `sshKeys` and `ipv4` (the
          VM's `cloudInit.network`) as they are, changed only where you mean to, or you remove the keys and switch
          the VM to DHCP.
        - **Ask the user first** before anything that loses data or cuts a guest off: deleting a VM, backup, image,
          target, job or webhook; restoring a backup, which replaces the VM's disks; `poweroff` and `reset`, which
          are like pulling the plug; and stopping or rebooting a VM that something else may be using. Prefer `stop`,
          a clean shutdown, to `poweroff`.
        - **Getting into a VM.** The API doesn't run commands in guests: use SSH. A running VM's `ip` shows up in
          `GET /api/vms`, a minute or so after its first boot. Log in as its `cloudInit.user` with a key in
          `cloudInit.sshKeys`. A new VM gets the Mac user's keys (`GET /api/host/sshkeys`) unless the request lists
          `sshKeys`, so to log in yourself, send those keys and yours (example below). A NAT VM (`192.168.64.x`) is
          reachable only from the Mac; a bridged one has an address on the LAN.
        - **On the Mac itself**, `Proxmacs cli` does the same from a shell; run it alone for the list of commands.

        """#
}
