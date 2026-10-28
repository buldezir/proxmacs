# Proxmacs web API

The web UI is a client of a JSON API on the same server, and scripts can use that API too: start and stop VMs,
take backups, read metrics and so on. The server is at `https://<mac>:8006` by default (`web.json` sets the port,
bind address and TLS; see the README).

For AI agents, the server serves this reference at `/llms.txt` (no login needed), after advice on using the API
safely: point an agent at `https://<mac>:8006/llms.txt` and give it an API key.

## Authentication

Programs authenticate with an **API key** sent in the `Authorization` header:

```bash
curl -H "Authorization: Bearer pmx_…" https://mac-mini.local:8006/api/vms
```

Create a key in the menubar (**Proxmacs menu → Web UI → API Keys…**) or with the CLI. A key is shown once, when
it's created; Proxmacs keeps only a hash of it. Name keys after what uses them, so you know which one to revoke.

```bash
Proxmacs cli api-key-add backup-script   # prints the key (only the key, on stdout)
Proxmacs cli api-keys                    # name, prefix, created, last used, id
Proxmacs cli api-key-rm backup-script    # revoke
```

(`Proxmacs` is `/Applications/Proxmacs.app/Contents/MacOS/Proxmacs`, or wherever the app is.)

For now every key has the same access as the admin password, so treat keys like the password. A request with an
`Authorization` header is checked against API keys only: a wrong or revoked key gets `401`, even if the request
also carries a login cookie.

The web UI itself logs in with the admin password (`POST /api/login`) and uses a session cookie. Mutating requests
that use the cookie must have `Content-Type: application/json` (a CSRF defence); requests with an API key need not.

### TLS

The default certificate is self-signed. Either trust it explicitly:

```bash
curl --cacert ~/Library/Application\ Support/Proxmacs/web/cert.pem -H "Authorization: Bearer $KEY" \
  https://mac-mini.local:8006/api/vms
```

(it's valid for the Mac's hostname, `<hostname>.local`, `localhost` and `127.0.0.1`; copy `cert.pem` to other
machines), or skip verification with `curl -k` after checking the SHA-256 fingerprint that `Proxmacs cli serve`
prints. Behind a reverse proxy with a trusted certificate (`tls` false, `bind` 127.0.0.1), use the proxy's URL.

## Conventions

- Request and response bodies are JSON. Fields not listed are ignored; a POST without a body is the same as `{}`.
- Errors are `{"error": "message"}` with a 4xx status: `400` invalid request, `401` not authenticated, `404` unknown
  VM, backup, target, job or webhook.
- Changes that finish at once return the updated object (or `204 No Content`).
- **Long operations** (create, start, stop, backups, restores, image downloads…) return `202 Accepted` with
  `{"task": "<id>"}` and run in the background. Follow them in `GET /api/tasks`: a task's `status` is `running`,
  then `ok` or `error`, and `message` says what happened. The newest 200 tasks are kept, in memory.
- VMs are addressed by name; offsite targets, backup jobs and webhooks by id. A `target` field in a request body
  takes a target's id or its name.
- Times are ISO 8601 (UTC). Metric samples carry `t` in milliseconds since 1970.

## Examples

```bash
export PMX=https://mac-mini.local:8006 KEY=pmx_…
api() { curl -sS --cacert ~/Library/Application\ Support/Proxmacs/web/cert.pem \
             -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" "$@"; }

# Running VMs and their IPs
api $PMX/api/vms | jq -r '.[] | select(.state == "running") | "\(.name)\t\(.ip)"'

# Wait for a task: prints its status and message, and fails unless it ended ok
wait_task() {
  local t
  until t=$(api $PMX/api/tasks | jq -c --arg id "$1" '.[] | select(.id == $id and .status != "running")') && [ -n "$t" ]; do
    sleep 2
  done
  jq -r '"\(.status): \(.message // "")"' <<<"$t"
  [ "$(jq -r .status <<<"$t")" = ok ]
}

# Back up web01 and wait for the result
wait_task "$(api -X POST $PMX/api/vms/web01/backup | jq -r .task)"

# Back up straight to an offsite target (id or name)
api -X POST -d '{"target": "nas"}' $PMX/api/vms/web01/backup

# Create a VM from Ubuntu 24.04 on the bridged network, with a static address
api -X POST $PMX/api/vms -d '{
  "name": "app01", "image": "ubuntu-24.04", "cpus": 2, "memoryMB": 4096, "diskGB": 30,
  "network": {"mode": "bridged"}, "user": "ubuntu", "sshKeys": ["ssh-ed25519 AAAA… me@laptop"],
  "ipv4": {"dhcp": false, "address": "192.168.1.50/24", "gateway": "192.168.1.1", "dns": ["192.168.1.1"]}
}'

# Clone a template and start the clone
api -X POST -d '{"name": "web02", "start": true}' $PMX/api/vms/debian-13-base/clone

# Create a VM you can log in to (with the Mac user's SSH keys and yours), wait for its address and SSH in
keys=$(api $PMX/api/host/sshkeys | jq --arg mine "$(cat ~/.ssh/id_ed25519.pub)" '. + [$mine]')
wait_task "$(api -X POST $PMX/api/vms -d "$(jq -n --argjson keys "$keys" '{name: "build01", sshKeys: $keys}')" | jq -r .task)" &&
  until ip=$(api $PMX/api/vms | jq -r '.[] | select(.name == "build01") | .ip // empty') && [ -n "$ip" ]; do sleep 5; done &&
  ssh debian@"$ip"
```

## Reference

### Session

| Method and path | Description |
| --- | --- |
| `GET /api/session` | `{authenticated, passwordSet}` for the session cookie (no authentication needed) |
| `POST /api/login` | `{"password": "…"}` → `204` and a session cookie (for browsers) |
| `POST /api/logout` | Ends the session |

### Host

| Method and path | Description |
| --- | --- |
| `GET /api/host` | Hostname, macOS and Tart versions, CPUs, memory, disk space, nested virtualization support, web UI URLs |
| `GET /api/host/stats` | Live CPU usage, load average, memory breakdown and pressure, memory assigned to running VMs |
| `GET /api/host/storage` | Where VM disks and backups are stored, and the external volumes they can move to |
| `PUT /api/host/storage` | `{"kind": "vms"\|"backups", "path": "/Volumes/…"}` (`path` null = back to the internal disk) → task |
| `GET /api/host/sshkeys` | The Mac user's SSH public keys |
| `GET /api/interfaces` | Network interfaces for bridging: `[{device, name, default}]` |
| `GET /api/tasks` | Task log, newest first: `[{id, vm, title, status, message, progress, started, finished}]` |

### Images

| Method and path | Description |
| --- | --- |
| `GET /api/images` | Catalog and imported images: `id`, `name`, `user`, `cached`, sizes, download progress |
| `POST /api/images/:id/download` | Download and convert a catalog image ahead of time → task |
| `DELETE /api/images/:id` | Delete a cached image |

### VMs

| Method and path | Description |
| --- | --- |
| `GET /api/vms` | All VMs (see below) |
| `POST /api/vms` | Create a VM → task. Body below |
| `PATCH /api/vms/:name` | Options: `autostart`, `tags`, `notes`, `startOrder` (null = unordered), `startDelay`, `backup` (retention), `offsite` (`{targets: [ids], auto}`) → VM |
| `PUT /api/vms/:name/hardware` | VM stopped: `cpus`, `memoryMB`, `diskGB` (grow only), `network`, `nested` → VM |
| `PUT /api/vms/:name/cloudinit` | `user` (required), `password` or `removePassword: true`, `sshKeys`, `ipv4`; applied on the next start → VM |
| `DELETE /api/vms/:name` | Delete the VM (local backups are kept) → task |
| `POST /api/vms/:name/start` | Start → task |
| `POST /api/vms/:name/stop` | Shut down through ACPI; turned off after 30 s → task |
| `POST /api/vms/:name/poweroff` | Turn off at once → task |
| `POST /api/vms/:name/reboot` | Reboot through the guest agent → task |
| `POST /api/vms/:name/reset` | Turn off and start again → task |
| `POST /api/vms/:name/clone` | `{"name": "new", "start": false, "ipv4": {…}}` → task |
| `POST /api/vms/:name/template` | `{"template": true\|false}`: templates can only be cloned → VM |
| `GET /api/vms/:name/metrics?range=hour\|day\|week` | `{range, step, samples: [{t, cpu, memory, guestUsed, guestTotal, diskRead, diskWrite, netIn, netOut}]}` |
| `GET /api/vms/:name/guest[?refresh=1]` | From the guest agent: OS, kernel, hostname, uptime, interfaces, filesystems (cached 30 s) |
| `POST /api/vms/:name/disks` | `{"sizeGB": 50}`: add an extra disk (VM stopped) → VM |
| `PUT /api/vms/:name/disks/:file` | `{"sizeGB": 80}` grow (VM stopped), `{"backup": false}` leave out of backups → VM |
| `DELETE /api/vms/:name/disks/:file` | Remove an extra disk (`disk1.img`, …; VM stopped) → VM |
| `POST /api/vms/:name/shares` | `{"name": "www", "path": "/Users/me/site", "readOnly": true}`: mounted at `/mnt/shared/<name>` (VM stopped) → VM |
| `DELETE /api/vms/:name/shares/:share` | Remove a shared folder → VM |

A VM object has `name`, `state` (`running`, `stopped`, …), `ip`, `network` (`{mode: "nat"|"bridged", interface}`),
`cpus`, `memoryMB`, `diskGB`, `autostart`, `template`, `tags`, `notes`, `startOrder`, `startDelay`, `nested`,
`disks`, `shares`, `cloudInit` (user, password `set`/`none`, SSH keys, IPv4), `backup` (retention), `offsite`,
`activity` (an operation in progress, or null) and `stats` (latest sample and `uptime` while running, else null).

Create body (only `name` is required):

| Field | Default | |
| --- | --- | --- |
| `name` | | Lowercase letters, digits and dashes |
| `image` | `debian-13` | An id from `GET /api/images` |
| `cpus`, `memoryMB`, `diskGB` | 2, 2048, 20 | |
| `network` | `{"mode": "nat"}` | `{"mode": "bridged", "interface": "en0"}`; without `interface`, the default route's |
| `user` | `debian` | Use the image's user (`GET /api/images`) |
| `password` | none | For the serial console; SSH password login stays off |
| `sshKeys` | none | OpenSSH public keys |
| `ipv4` | DHCP | `{"dhcp": false, "address": "CIDR", "gateway": "IP", "dns": ["IP"]}` |
| `autostart` | false | Start on login |
| `startNow` | true | |

### Local backups

| Method and path | Description |
| --- | --- |
| `POST /api/vms/:name/backup` | Back up now → task. `{"target": "<id or name>"}` backs up straight to an offsite target |
| `GET /api/vms/:name/backups` | `[{id, date, consistent, source}]`, newest first |
| `POST /api/vms/:name/backups/:id/restore` | Restore (VM stopped) → task |
| `POST /api/vms/:name/backups/:id/push` | `{"target": "<id or name>"}`: upload to an offsite target → task |
| `DELETE /api/vms/:name/backups/:id` | Delete a local backup |

### Offsite targets

| Method and path | Description |
| --- | --- |
| `GET /api/targets` | `[{id, name, kind, location, keep, smb, pbs}]` |
| `POST /api/targets` | SMB: `{"name", "kind": "smb", "keep": 7, "smb": {"url": "smb://user@host/share/path", "password"}}`; PBS: `{"name", "kind": "pbs", "keep", "pbs": {"host", "port": 8007, "datastore", "namespace", "authId": "user@pbs!token", "secret", "fingerprint"}}` |
| `DELETE /api/targets/:id` | Remove (refused while a backup job uses it) |
| `POST /api/targets/:id/test` | `{ok, message}` |
| `GET /api/targets/:id/snapshots?vm=NAME` | `[{vm, time, id}]` |
| `POST /api/targets/:id/pull` | `{"vm", "id"}`: download into local backups; recreates the VM if it doesn't exist → task |
| `POST /api/targets/:id/verify` | `{"vm", "id"}`: read every chunk back and check it → task |

### Backup jobs

| Method and path | Description |
| --- | --- |
| `GET /api/jobs` | Jobs with `schedule`, `nextRun`, `lastRun`, `lastOK`, `lastMessage`, `running` |
| `POST /api/jobs` | Create (fields below) → job |
| `PUT /api/jobs/:id` | Change any fields → job |
| `DELETE /api/jobs/:id` | Delete |
| `POST /api/jobs/:id/run` | Run now → task |

Job fields: `enabled` (true), `comment`, `days` (ISO weekdays 1 = Monday … 7 = Sunday; empty = every day),
`hour`, `minute`, `selection` (`all`, `include` or `exclude`) with `vms`, `target` (offsite target id; null =
local backups), `notify` (`never`, `failure` or `always`).

### Notification webhooks

| Method and path | Description |
| --- | --- |
| `GET /api/notifications` | `[{id, name, enabled, format, host}]` (the URL is never returned) |
| `POST /api/notifications` | `{"name", "format": "json"\|"discord"\|"slack"\|"ntfy", "url", "enabled"}` |
| `PUT /api/notifications/:id` | Change fields; omit `url` to keep the stored one |
| `DELETE /api/notifications/:id` | Delete |
| `POST /api/notifications/:id/test` | Send a test notification: `{ok, message}` |

### Serial console

`GET /api/vms/:name/console` upgrades to a WebSocket (`wss://` with TLS) attached to the VM's serial console
(the VM must be running). The server first sends recent output, then everything the guest prints, as binary
messages; text or binary messages from the client are typed into the console. For example, with
[websocat](https://github.com/vi/websocat):

```bash
websocat -k -H "Authorization: Bearer $KEY" wss://mac-mini.local:8006/api/vms/web01/console
```

### Display (VNC)

`GET /api/vms/:name/vnc/ws` upgrades to a WebSocket (`wss://` with TLS) that relays the guest's Screen Sharing
service (RFB, `<guest ip>:5900`) byte for byte — a websockify-style bridge for a client like noVNC. The VM must be
running and have an address. Frames in both directions are raw RFB (binary WebSocket messages, with text treated as
its UTF-8 bytes); the client negotiates RFB itself, including Apple ARD auth (type 30) with a guest macOS account.
Nothing is rewritten. The server closes the socket with a reason string when the VM isn't running or has no address,
nothing listens on port 5900, or macOS Local Network privacy is blocking the connection. When Screen Sharing is off in
a macOS guest, the close code is `4001`.

| Route | What it does |
| --- | --- |
| `POST /api/vms/:name/vnc/setup` | macOS guests: turns Screen Sharing on if nothing listens on 5900, otherwise grants local accounts observe-and-control if nobody has any. Needs the tart guest agent and passwordless `sudo` in the guest. → `{"changed": bool, "message": "…"}` |

Credentials for that account are kept in `secrets.json` and managed with:

| Route | What it does |
| --- | --- |
| `GET /api/vms/:name/vnc/credentials` | `{username, password}`, each `null` when nothing is stored. The one endpoint that returns a stored secret, because the browser needs it to answer the RFB handshake, so it takes a web UI session only: an API key gets 403 |
| `PUT /api/vms/:name/vnc/credentials` | `{"username": …, "password": …}` → 204 |
| `DELETE /api/vms/:name/vnc/credentials` | Forget the pair → 204 |
