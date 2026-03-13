# DevLab — macOS Dev-Lab Bootstrapper

Turns your Mac into a local development lab that starts automatically at every login, serves a token-protected status API over HTTPS, and can optionally share via Bonjour.

---

## Requirements

| Requirement | Notes |
|---|---|
| macOS 12 Monterey or later | `launchctl bootstrap`/`kickstart` require macOS 11+ |
| Node.js LTS | stdlib-only; no `npm install` needed. Download from [nodejs.org](https://nodejs.org/) |
| No root required | All files live under `~/devlab` and `~/Library/LaunchAgents` |
| No Homebrew required | All tools used (`dns-sd`, `launchctl`, `osascript`, `ifconfig`) ship with macOS |

---

## File structure

```
~/devlab/
├── install-devlab.sh        ← Run this once to bootstrap everything
├── uninstall-devlab.sh      ← Fully removes the lab
├── start-devlab.sh          ← Entry point called by launchd at every login
├── status-devlab.sh         ← Human-readable health check
├── devlab-server.js         ← Dependency-free Node.js HTTPS/HTTP status server
├── enable-hotspot.applescript ← Optional: best-effort Internet Sharing toggle
├── config/
│   ├── com.diogo.devlab.plist  ← Backup copy of the LaunchAgent plist
│   ├── token                ← Bearer token used by API authentication (`chmod 600`)
│   ├── server.key.pem       ← Self-signed TLS private key
│   ├── server.cert.pem      ← Self-signed TLS certificate
│   └── README.txt           ← Config and security notes
└── logs/
    ├── start.log            ← start-devlab.sh stdout
    ├── error.log            ← start-devlab.sh stderr
    ├── server.out.log       ← Node server stdout
    ├── server.err.log       ← Node server stderr
    ├── mdns.out.log         ← dns-sd stdout
    ├── mdns.err.log         ← dns-sd stderr
    ├── hotspot.out.log      ← AppleScript helper stdout
    ├── hotspot.err.log      ← AppleScript helper stderr
    ├── launchd.out.log      ← launchd-captured stdout
    └── launchd.err.log      ← launchd-captured stderr

~/Library/LaunchAgents/
└── com.diogo.devlab.plist   ← LaunchAgent (auto-start at login, keep-alive)
```

---

## Quick start

### 1. Copy the installer to `~/devlab`

```bash
mkdir -p ~/devlab
cp install-devlab.sh ~/devlab/install-devlab.sh
chmod +x ~/devlab/install-devlab.sh
```

> If you have cloned this repository into a different folder, you can run the installer directly from any path — it will copy itself to `~/devlab` automatically.

### 2. Install Node.js (if not already installed)

Download the LTS installer from [https://nodejs.org/](https://nodejs.org/) and run it.

Verify:
```bash
node --version   # e.g. v22.x.x
```

### 3. Run the installer

```bash
bash ~/devlab/install-devlab.sh
```

The installer will:
1. Create `~/devlab/`, `~/devlab/logs/`, and `~/devlab/config/`
2. Write all companion files (`start-devlab.sh`, `devlab-server.js`, etc.)
3. Write `~/Library/LaunchAgents/com.diogo.devlab.plist`
4. Generate a random 64-char hex auth token at `~/devlab/config/token` (mode `0600`)
5. Generate a self-signed TLS certificate with SANs for `localhost` and `127.0.0.1`
6. Attempt to trust that certificate in your login keychain automatically
7. Unload any previous version of the LaunchAgent cleanly
8. Bootstrap and kickstart the new LaunchAgent immediately
9. Print next steps, the auth token value, and troubleshooting hints

The installer is **idempotent** — you can run it again safely at any time.

### 4. Verify installation

```bash
bash ~/devlab/status-devlab.sh
curl -k -H "Authorization: Bearer $(cat ~/devlab/config/token)" https://127.0.0.1:3000
```

---

## Practical out-of-the-box examples

These are concrete things you can do immediately after install, without adding any dependencies.

### 1) Fast "is my Mac dev stack alive?" check

Use this before coding sessions, demos, or when waking from sleep:

```bash
bash ~/devlab/status-devlab.sh
```

You get launchd/job status, process PIDs, IP addresses, an authenticated API probe, and log-file hints in one command.

### 2) Use DevLab as a local health endpoint for scripts

Return non-zero if DevLab is unhealthy (useful in shell scripts / CI-on-local-machine checks):

```bash
curl -fsS -k \
  -H "Authorization: Bearer $(cat ~/devlab/config/token)" \
  https://127.0.0.1:3000 >/dev/null
```

If this command exits with code `0`, the service is reachable and authenticated.

### 3) Run a tiny "pre-flight" gate before starting work

```bash
if curl -fsS -k -H "Authorization: Bearer $(cat ~/devlab/config/token)" https://127.0.0.1:3000 >/dev/null; then
  echo "DevLab OK — start coding"
else
  echo "DevLab not ready — run: bash ~/devlab/status-devlab.sh"
fi
```

### 4) Monitor uptime continuously in a separate terminal

```bash
while true; do
  date
  curl -s -o /dev/null -w "HTTP %{http_code}\n" -k \
    -H "Authorization: Bearer $(cat ~/devlab/config/token)" \
    https://127.0.0.1:3000
  sleep 30
done
```

Good for long-running local jobs where you want a quick heartbeat.

### 5) Share status API on your LAN for temporary team demos

1. Set `BIND_ADDR=0.0.0.0` in `~/Library/LaunchAgents/com.diogo.devlab.plist`
2. Optionally set `ADVERTISE_SERVICE=1`
3. Reload launchd (see [Configuration](#configuration))

Then teammates on the same trusted network can resolve/discover the service and call it with the token.

### 6) Quick recovery when something looks off

```bash
launchctl kickstart -k gui/$(id -u)/com.diogo.devlab
bash ~/devlab/status-devlab.sh
```

If that still fails, use the reset flow in [Troubleshooting](#troubleshooting).

---

## Why this is cool

DevLab gives you production-like service behavior on a personal Mac, without production-level overhead.

- **Feels like real infrastructure:** auto-start at login, `launchd` keep-alive, and predictable process lifecycle
- **Secure by default:** loopback bind, HTTPS enabled, token auth, timing-safe comparison, and request rate limiting
- **Operationally usable:** one command health check plus focused logs for startup, runtime, and launchd-level failures
- **Minimal setup burden:** no root, no Homebrew, no extra runtime dependencies beyond Node.js
- **Grows with your needs:** stay local-only for safety, or intentionally enable LAN + Bonjour for team demos
- **Easy to maintain:** idempotent installer, clean uninstall path, and fast restart/reset workflows

In short: it helps you adopt a small "production mindset" locally — automation, security, observability, and repeatability.

---

## Testing

This repository includes automated tests for the Node server and installer smoke paths.

Run the suite:

```bash
npm test
```

Run with coverage:

```bash
npm run coverage
```

Coverage notes:

- The Node server code is covered by automated tests.
- The installer is covered by smoke tests in a temporary home directory with stubbed system tools.
- Shell scripts are still validated with `bash -n`, but they are not unit-tested line-by-line.

---

## Automated vs Manual

Done automatically by the installer:

- Create the full `~/devlab` directory structure
- Generate the auth token
- Generate the TLS key/certificate
- Attempt to trust the TLS certificate in your login keychain
- Install and load the LaunchAgent
- Start the local service immediately

Still manual by design:

- Enabling LAN mode (`BIND_ADDR=0.0.0.0`)
- Enabling Bonjour visibility (`ADVERTISE_SERVICE=1`)
- Enabling hotspot automation (`ENABLE_HOTSPOT=1`)
- Granting Accessibility permissions for hotspot UI scripting
- Trusting the certificate manually if Keychain trust fails automatically

---

## What happens at each login

`launchd` reads `~/Library/LaunchAgents/com.diogo.devlab.plist` and calls `start-devlab.sh`, which:

1. **Terminates** any leftover devlab processes from a previous session (using PID files)
2. **Starts** `devlab-server.js` on `127.0.0.1:3000` with TLS enabled by default
3. **Optionally runs** the service on the local network via Bonjour (`ADVERTISE_SERVICE=1`)
4. **Optionally runs** the AppleScript Internet Sharing helper (disabled by default)
5. **Waits** on the Node process; if it exits, launchd restarts the whole job (`KeepAlive true`)

---

## HTTPS status API

Once running, the server responds to authenticated **HTTPS** requests on port 3000.

```bash
curl -k -H "Authorization: Bearer $(cat ~/devlab/config/token)" https://127.0.0.1:3000
```

Example response:

```json
{
  "ok": true,
  "service": "Diogo Dev Lab",
  "timestamp": "2026-03-13T10:00:00.000Z",
  "hostname": "Naubly-MacBook-Air.local",
  "ipv4": ["192.168.1.42"],
  "requestUrl": "/",
  "requestMethod": "GET"
}
```

The server binds to `BIND_ADDR` (default `127.0.0.1`, loopback-only). You can set `BIND_ADDR=0.0.0.0` only when you intentionally want LAN access.

### Supported methods and responses

| Method | Result |
|---|---|
| `GET`, `HEAD` | `200` on success |
| Other methods | `405 Method not allowed` |
| Missing/invalid token | `401 Unauthorized` + `WWW-Authenticate: Bearer realm="devlab"` |
| Exceeds rate limit | `429 Too many requests` |

---

## Authentication

The installer creates `~/devlab/config/token` (mode `0600`) containing a random 64-character hex string. Every API request must include this token.

**Get your token:**
```bash
cat ~/devlab/config/token
```

**Make an authenticated request:**
```bash
curl -k -H "Authorization: Bearer $(cat ~/devlab/config/token)" https://127.0.0.1:3000
```

Requests without a valid token return `HTTP 401 Unauthorized`. The comparison is **timing-safe** (constant-time XOR loop) to prevent oracle attacks.

**Rate limiting:** each IP is limited to 30 requests per minute. Excess requests return `HTTP 429 Too Many Requests`.

**TLS by default:** the installer generates a self-signed certificate and key in `~/devlab/config/` and starts the server in HTTPS mode.

### Cert trust options

By default, examples use `curl -k` because the cert is self-signed.

If you want to remove `-k`, trust the generated certificate in Keychain:

1. Open **Keychain Access**
2. Import `~/devlab/config/server.cert.pem`
3. Set trust to **Always Trust** for SSL

Then test without `-k`:

```bash
curl -H "Authorization: Bearer $(cat ~/devlab/config/token)" https://127.0.0.1:3000
```

**Rotate the token** (invalidates all existing clients):
```bash
LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 64 > ~/devlab/config/token
chmod 600 ~/devlab/config/token
# Restart the Node server to pick up the new token:
launchctl kickstart -k gui/$(id -u)/com.diogo.devlab
```

---

## Local network discovery (Bonjour)

The service can be advertised as `_https._tcp` with a TXT record of `path=/` when `ADVERTISE_SERVICE=1`.

By default, advertisement is disabled to reduce local-network discoverability.

**Browse for it from another machine on the same LAN:**
```bash
dns-sd -B _https._tcp local
```

**Resolve the IP and port:**
```bash
dns-sd -L "Diogo Dev Lab" _https._tcp local
```

**On iOS / Android:** Any Bonjour browser app (e.g. Discovery, LAN Scan) will list _Diogo Dev Lab_.

### Enabling LAN mode safely

If you need other machines to reach the API:

1. Set `BIND_ADDR` to `0.0.0.0`
2. Set `ADVERTISE_SERVICE` to `1` (optional)
3. Keep `ENABLE_TLS=1`
4. Reload launchd (see Configuration section)

Only do this on trusted networks.

---

## Checking status

```bash
bash ~/devlab/status-devlab.sh
```

This prints:
- Whether the LaunchAgent plist exists
- Whether the `launchd` job is loaded
- Running PIDs for the Node server and `dns-sd` advertisement
- All non-loopback IPv4 addresses
- Result of a `curl` probe to `https://127.0.0.1:3000` (with token and `-k` when TLS is enabled)
- Presence of each log file with their paths
- Remediation hints for common failures

---

## Configuration

Environment variables are set in the plist and passed to `start-devlab.sh`:

| Variable | Default | Description |
|---|---|---|
| `PORT` | `3000` | TCP port the HTTP server listens on |
| `SERVICE_NAME` | `Diogo Dev Lab` | Bonjour service name visible to other devices |
| `ENABLE_HOTSPOT` | `0` | Set to `1` to run the Internet Sharing AppleScript helper |
| `BIND_ADDR` | `127.0.0.1` | Bind address. Set to `0.0.0.0` only when LAN access is intentionally required |
| `TOKEN_FILE` | `~/devlab/config/token` | Path to the auth token file read at server startup |
| `ADVERTISE_SERVICE` | `0` | Set to `1` to share via Bonjour (`_https._tcp`) |
| `ENABLE_TLS` | `1` | TLS mode for the API server |
| `TLS_KEY_FILE` | `~/devlab/config/server.key.pem` | TLS private key path |
| `TLS_CERT_FILE` | `~/devlab/config/server.cert.pem` | TLS certificate path |

### Recommended secure defaults

- `BIND_ADDR=127.0.0.1`
- `ENABLE_TLS=1`
- `ADVERTISE_SERVICE=0`
- `ENABLE_HOTSPOT=0`

To change a value, edit `~/Library/LaunchAgents/com.diogo.devlab.plist`, then reload:

```bash
DOMAIN="gui/$(id -u)"
PLIST=~/Library/LaunchAgents/com.diogo.devlab.plist

launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/com.diogo.devlab"
```

---

## Security measures

| Control | Detail |
|---|---|
| **Token authentication** | Every HTTP request requires `Authorization: Bearer <token>` matching `~/devlab/config/token` |
| **Timing-safe comparison** | Token is compared with a constant-time XOR loop — no timing oracle |
| **Rate limiting** | 30 req/min per IP; excess → `429 Too Many Requests` (in-memory, no deps) |
| **Security headers** | `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Cache-Control: no-store`, `Content-Security-Policy: default-src 'none'` |
| **Configurable bind address** | `BIND_ADDR=127.0.0.1` locks the server to loopback when on untrusted networks |
| **Token file permissions** | Created with `chmod 600` — unreadable by other local users |
| **HTTPS enabled by default** | Self-signed cert generated during install; status/test commands use `curl -k` |
| **Advertisement off by default** | `ADVERTISE_SERVICE=0` reduces LAN discoverability unless explicitly enabled |

### Threat model summary

- Designed for local-machine diagnostics first (loopback HTTPS by default)
- Can be opened to LAN intentionally, but only with explicit config changes
- Does not include user accounts or multi-user RBAC; auth is a single token

---

## Optional: Internet Sharing / hotspot

`enable-hotspot.applescript` attempts to open System Settings and toggle Internet Sharing via UI scripting.

**To enable it:**
1. Set `ENABLE_HOTSPOT` to `1` in the plist (see Configuration above)
2. Go to **System Settings → Privacy & Security → Accessibility** and grant permission to Terminal (or whichever app runs `osascript`)
3. Reload the LaunchAgent (see reload steps above)

> **Security note:** If you enable a hotspot, always set a WPA2/WPA3 password. An open hotspot is a significant security risk.

See [Known limitations](#known-limitations) for why this may not work reliably.

---

## Logs

All log files live under `~/devlab/logs/`.

**Follow live output:**
```bash
tail -f ~/devlab/logs/start.log ~/devlab/logs/error.log
tail -f ~/devlab/logs/server.out.log ~/devlab/logs/server.err.log
```

**Check launchd output directly (captured by the plist):**
```bash
tail -f ~/devlab/logs/launchd.out.log ~/devlab/logs/launchd.err.log
```

**Check the system launchd database:**
```bash
launchctl print gui/$(id -u)/com.diogo.devlab
```

### Most useful log files first

- `~/devlab/logs/error.log` (startup wrapper errors)
- `~/devlab/logs/server.err.log` (Node runtime errors)
- `~/devlab/logs/launchd.err.log` (launchd-level stderr)

---

## Uninstall

```bash
bash ~/devlab/uninstall-devlab.sh
```

This will:
1. Unload the LaunchAgent from launchd
2. Remove `~/Library/LaunchAgents/com.diogo.devlab.plist`
3. Terminate any running devlab processes
4. Prompt you whether to delete `~/devlab` entirely

---

## Troubleshooting

| Symptom | What to check |
|---|---|
| `launchd job: not loaded` | Run `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.diogo.devlab.plist` |
| `curl probe: failed` | Check `~/devlab/logs/server.err.log` and `~/devlab/logs/error.log` |
| `node server: not running` | Verify `command -v node` works; check `~/devlab/logs/server.err.log` |
| `dns-sd advertisement: not running` | Check `~/devlab/logs/mdns.err.log`; confirm `/usr/bin/dns-sd` exists |
| TLS handshake/cert warning | Expected with self-signed cert. Use `curl -k` or trust cert in Keychain |
| `FATAL: could not load token` | Ensure `~/devlab/config/token` exists and is readable by your user |
| `TLS is enabled but key/cert missing` | Re-run installer or create cert/key in `~/devlab/config` |
| Node not found at launchd startup | Add Node's install directory (e.g. `/usr/local/bin`) to the `PATH` inside the plist `EnvironmentVariables` block |
| Hotspot script fails | Check `~/devlab/logs/hotspot.err.log`; verify Accessibility permission for Terminal |
| Port 3000 already in use | Change `PORT` in the plist to another value (e.g. `3001`) and reload |

**Manually test the LaunchAgent without rebooting:**
```bash
launchctl kickstart -k gui/$(id -u)/com.diogo.devlab
```

**Force-stop and restart:**
```bash
launchctl stop com.diogo.devlab
launchctl start com.diogo.devlab
```

### Full reset (safe recovery)

If state gets inconsistent, run:

```bash
bash ~/devlab/uninstall-devlab.sh
bash ~/devlab/install-devlab.sh
bash ~/devlab/status-devlab.sh
```

---

## Firewall notes

macOS may prompt you to allow incoming connections for `node` the first time the server starts. Click **Allow**.

If the firewall is managed by policy (e.g. corporate MDM), you may need to add a rule for `node` manually in **System Settings → Network → Firewall → Options**.

Default mode binds loopback only (`127.0.0.1`), so remote hosts cannot connect unless you explicitly set `BIND_ADDR=0.0.0.0`.

If you intentionally enable LAN mode, consider adding a firewall allow-list or restricting network profile manually.

---

## Known limitations

- **Internet Sharing automation is fragile.** Apple's System Settings UI layout changes with macOS updates. The AppleScript may stop working after an OS upgrade without any code change.
- **Hotspot auto-enable may fail silently.** The script catches errors and logs them, but cannot guarantee the hotspot is actually enabled. Always verify manually in System Settings.
- **Accessibility permission is required.** Without it, `osascript` cannot send keystrokes to System Settings. This can only be granted manually by the user in System Settings → Privacy & Security → Accessibility.
- **Clients must join the hotspot manually at least once.** Even if the hotspot is enabled automatically, other devices cannot join without user interaction on their end.
- **Node must be on PATH when launchd runs.** At login, launchd has a minimal `PATH`. If `node` is installed in a non-standard location (e.g. via `nvm` or `fnm`), add the full path to the `PATH` key in the plist `EnvironmentVariables`, or set `NODE_BIN` explicitly in `start-devlab.sh`.
