# Swiftty: Connect to Mac

**Scope:** connecting an iPhone or iPad (`MobileClient`) to the native Swiftty
Mac app, then choosing a workspace. This document adds a connection and
workspace-selection step. It does not change SMX/2, RST/1, the native window
model in [spec.md](spec.md) and [spec.multiplexer.md](spec.multiplexer.md),
or the ownership and lease rules in [spec.inbox.md](spec.inbox.md), which
remain authoritative where they apply.

Initial product scope is the native Swiftty host app (`Sources/Swiftty`) and
`MobileClient`. Shared code builds for the other direct clients. Discovery
and camera scanning are gated by `PlatformProfile.nearbyDiscovery` and
`PlatformProfile.codeScanning`, which are enabled only on iPhone and iPad.
Pasting a code (`codeImport`) is available on every direct client except
tvOS. The watch companion is unchanged.

## 1. User flow

### 1.1 On the Mac: Terminal Service › Connect a Device…

The panel (`ConnectDevicePanel.swift`) shows the following:

- **Connection details** (editable): SSH host name or address, SSH port and
  account name. The default host is `<LocalHostName>.local`, the Bonjour
  host name, not the Mac's display name. Wildcard and loopback addresses
  (`0.0.0.0`, `::`, `::1`, `localhost`, `127.*`) are refused. A nondefault
  SSH port must be confirmed before it is shared. `.local` names and private
  addresses are labelled as working only on the local network, or on a VPN
  the user configured to carry them, and never over cellular.
- **Roaming endpoint (configured):** the `advertisedHost` and UDP `port` from
  the SwiftMux roaming configuration. This is a configured value, not a
  verified one. If roaming is not configured, the panel shows setup
  instructions.
- **Status (checked on this Mac):** whether an SSH server answers on the
  chosen port on loopback (the probe reads the protocol banner), and
  `swifttyd status`, which is a read-only list request. A local answer does
  not prove that another device can reach the Mac. When SSH does not answer,
  the panel tells the user how to turn on Remote Login.
- **SSH host keys:** the fingerprints of `/etc/ssh/ssh_host_*_key.pub`. Only
  `.pub` files are opened, and symlinks are not followed. If no supported key
  can be read, the panel offers no pairing code and asks the user to enter
  the details manually.
- **Show Pairing Code:** a QR code of the descriptor in §2, with an explicit
  **Copy Code** button for pasting.
- **Make Discoverable While This Panel Is Open:** a `_swiftty._tcp`
  registration (§3) owned by the foreground app. It is withdrawn when the
  user turns it off, edits the endpoint, closes the panel or quits.

Opening the panel creates no workspace, mints no grant, and changes nothing
on the Mac. Remote Login, the firewall, `authorized_keys`, the agent and the
roaming configuration stay under the existing explicit setup workflow
(`Scripts/install.sh --roaming`). Saved hosts keep working when the Mac is
not advertising.

### 1.2 On the iPhone or iPad: Connect to Mac

**Settings › Connect to Mac** offers these entries:

| Entry | What it does |
|---|---|
| Nearby Macs | Browses `_swiftty._tcp` while the sheet is open (§3). Choosing a Mac resolves it to a host name and port. |
| Scan Mac Code | Starts the camera only in this sheet. A valid code stops the camera; refused camera access offers Paste instead. |
| Paste Mac Code | Decodes a pasted code. The pasteboard is read only through the explicit Paste control. |
| Enter Address Manually | The existing Add Host form (`HostEditorView`, `HostProfile.validate()`). |

Discovery and scanning produce a temporary `HostCandidate`. The candidate
saves nothing and trusts nothing; it does not authenticate, create a
workspace, acquire a lease or detach the active terminal. The candidate opens
in `HostEditorView` in confirmation mode, which shows the following:

- the host, port and account, all editable;
- for a code, the expected SSH key fingerprints, and a required
  confirmation that the code came from the intended Mac;
- for a nearby result, a note that a network name is not proof of
  identity;
- an explicit **Save as** choice when a saved host already has the same
  host and port. A nickname or discovered name never merges hosts.

**Connect** runs `RoamingAppModel.pair` in this order:

1. With a code, the key check runs before any credential is requested. If
   the trust store already holds a key for that host and port, and the code
   does not name it, pairing is blocked without contacting the server.
   Otherwise a credential-free probe (`SSHConnection.verifyHostKey`) checks
   the presented key against the code first, then against the trust store.
   An unknown key that matches still needs an explicit **Trust**; the prompt
   shows "Matches the connection code you confirmed".
2. Approved keys are stored through the existing `FileHostTrustStore`. The
   stored key is the server's actual key, never the code's fingerprint. A
   changed key still blocks. A code never replaces a trusted key.
3. The user signs in as usual.
4. The confirmed `HostProfile` is saved in the connection snapshot described by
   [spec.ssh-identity.md](spec.ssh-identity.md). Pairing adds no stored password
   or pin field. The account generation and target record revision reviewed
   before pairing must still match after SSH closes; otherwise saving fails
   and the workspace chooser does not open.
5. The workspace chooser opens.

Cancelling at any point discards the candidate.

Host editors, retained row edit/delete actions, and **Save as** choices keep the
account generation, scope, record revision, and conflict state they reviewed.
An account switch, including switching away and back, or a changed target
invalidates that action.
Preserve the draft and ask the user to reopen or reselect the host rather than
overwriting a replacement record with the same UUID. New drafts reserve their
UUID too. Unrelated host changes do not invalidate an edit. Hidden, displaced,
or tombstoned records cannot be changed through an old save/delete callback;
a refused save must not report success or close the editor.

Host-row connection callbacks validate their selection before starting an action.
The workspace chooser retains that selection through delayed presentation,
authentication and metadata replies. A stale
chooser cannot create, resume or confirm takeover on a replacement record,
even when its UUID and profile fields are identical. It closes its metadata
connection and asks the user to reopen the host; an existing terminal remains
untouched. Successful legacy-key migration can update the chooser to the
verified label mapping for the otherwise unchanged host in the same account.

### 1.3 Mac → Workspace

Tapping a saved host opens `WorkspaceChooserView`. It signs in, which means
host-key verification and then authentication, and lists workspaces with
`BootstrapRequest(operation: .attention, attention: .workspaces)` over the
existing `RoamingAttentionService`. For each workspace, the chooser shows the
name, tab and pane counts, running panes, and control state: not attached,
shown on this device, controlled on the Mac, or controlled by another device.

“Shown on this device” requires the active roaming screen's captured owner to
match the selected host UUID, account scope, normalized endpoint and remote
username. Reusing host/workspace UUIDs under another owner must not suppress
takeover confirmation. The fresh lease check uses that same ownership rule;
confirmed takeover still names the displayed lease generation. Display-name or
credential changes alone do not turn the existing connection into another owner.

| Action | Result |
|---|---|
| Choose a free workspace | `WorkspaceIntent.resume(SessionID(id), nil)` |
| Choose one held elsewhere | Asks for confirmation, then re-reads metadata. If the service epoch and lease generation are unchanged, it sends `ResumeTarget(expectedLease:)` with the displayed generation; otherwise it refreshes the list without retrying. |
| New Workspace | `WorkspaceIntent.create`, the only create request. An empty list offers it but never runs it automatically. |
| Cancel, refresh or dismiss | Closes the metadata connection and nothing else. |

Selecting a workspace goes through `RoamingAppModel.openWorkspace`. That
method uses the existing single-active-terminal transition: the previous
terminal detaches, and its processes are never ended. Choosing the workspace
that is already shown changes nothing.

`RoamingTerminalController.StartChoice.automatic` has been replaced. A screen
attaches according to its explicit `WorkspaceIntent`. A retry reattaches the
workspace that was granted, so a create is never repeated. Without an
explicit choice, a screen resumes only a remembered workspace. If no
workspace is remembered, the screen shows "Choose a workspace" and creates
nothing until the user chooses **New Workspace**. **Resume Last
Workspace** (in the host's context menu) names the remembered identity and
never falls back to creating a workspace. Attention-link reveals and
reconnects keep their existing semantics.

A retained **Resume Last Workspace** menu action resumes the exact ID in its
displayed label after validating its captured host context. A later saved-choice
update or removal cannot substitute another workspace. Deleting a saved host
closes only a terminal with that host's captured owner; a retained connection
for a different account or endpoint remains open even when its UUID is reused.

An explicit intent belongs to the terminal screen that was opened for it, not
to a future screen with the same host UUID. Closing that screen discards an
unconsumed intent. Persisted resume choices are scoped by account and endpoint
as specified in [the roaming lifecycle](spec.roaming.md#9-apple-client-lifecycle-and-network-recovery).
Older UUID-only choices require selecting the workspace again from the chooser.

## 2. Pairing code (`HostConnection` target)

`HostConnectionDescriptor` is defined in the Foundation-only `HostConnection`
target. Both the native exporter and the client importer use it.

```json
{"hostKeys":[{"algorithm":"ssh-ed25519","sha256":"SHA256:<43 base64 chars>"}],
 "kind":"swiftty-host","name":"My MacBook",
 "ssh":{"host":"macbook.local","port":22,"username":"chris"},"version":1}
```

The decoder enforces these rules:

- total input of at most 2,048 bytes;
- `kind` must be `swiftty-host` and `version` must be `1`;
- unknown fields at any level are rejected;
- `host` must be an LDH DNS name of 1–253 bytes, or an IPv4 or unscoped IPv6
  literal. URLs, ports, user info, scopes and trailing dots are refused;
- `port` must be an integer from 1 to 65535. Booleans and fractions are
  refused;
- `username` must be a POSIX-style short name;
- `name`, if present, must be at most 64 characters of printable display
  text, with no controls, URLs or shell syntax;
- `hostKeys` must contain one to four distinct entries, each using
  `ssh-ed25519` or `ecdsa-sha2-nistp256/384/521` (the algorithms the
  clients verify), with a canonical unpadded `SHA256:` fingerprint of a
  32-byte digest.

A fingerprint is the SHA-256 of the SSH public-key wire blob, which is the
format `SSHPublicKeyFormat.fingerprint` displays. It is never a QUIC
certificate or SPKI pin. Decoding performs no network request. A code holds
no passwords, private keys, RST tokens, session or workspace identifiers,
commands, helper paths or actions, and it is not a bearer authorization. No
URL scheme or Universal Link is added; existing attention links are
unchanged.

## 3. Bonjour discovery

| Item | Value |
|---|---|
| Service type | `_swiftty._tcp`, a product identifier, not an assigned port or protocol |
| Domain | `local.` only; no wide-area registration or browsing, and no NAT mapping |
| TXT | `txtvers=1`, `product=swiftty`; nothing else |
| Port | The Mac's existing SSH port, as chosen in the panel |

**Mac.** `HostAdvertiser` and `DNSSDRegistrar` call `DNSServiceRegister` for
the existing SSH endpoint. They open no listener and start no SSH or pairing
server. The instance name is the sanitized computer name. The system may
rename it on a collision, and the panel shows the final name.

**Client.** `NearbyMacBrowser` runs one `NWBrowser` for the declared type. It
starts only when Nearby Macs appears and stops on dismissal or backgrounding.
It keeps running while the scene is inactive, for example while the system
permission alert is shown. `NearbyCandidateList` applies these bounds:

- at most 256 candidates;
- TXT records of at most 512 bytes with the right product and version;
- the right type and domain;
- instance names of at most 63 bytes that sanitize to non-empty display
  text;
- records with the same raw name are grouped for display only. Matching names
  are never proof of identity.

Choosing a candidate resolves only that one with `DNSServiceResolve` on its
own interface, and supersedes any earlier resolution. Late, superseded and
withdrawn answers are ignored. The result is the record's host target (for
example `MacBook.local`) and port. That host name is preferred over a
transient address, and the system resolver applies the interface scope when
SSH connects, so no IPv6 scope is stripped. The browser never scans other
types, probes a subnet, uses raw multicast, or connects by itself.

The browser reports distinct states: searching, results, no results after a
quiet period (which says nothing about permission), policy denial (only
`kDNSServiceErr_PolicyDenied`), and other failures. **Try Again** starts a
fresh browse, for example after the user returns from Settings.

## 4. Permissions and packaging

| Location | Declaration |
|---|---|
| `Apps/project.yml` (all direct clients) | `NSLocalNetworkUsageDescription`: "Find and connect to your Mac to access terminal workspaces on your local network." |
| `Apps/project.yml` (`MobileClient` only) | `NSCameraUsageDescription`: "Scan the connection code displayed by your Mac." |
| `Apps/Config/AttentionLinks.plist`, copied by `Scripts/configure-links.sh` | `NSBonjourServices` = `[_swiftty._tcp]`, as a real array. URL schemes and domains are unchanged. |
| `Scripts/package-swiftmux.sh` (`Swiftty.app`) | `NSLocalNetworkUsageDescription` and the same `NSBonjourServices`. Signing and the optional associated-domains entitlement are unchanged. |
| Watch | No discovery, camera or new permissions |

No configuration requests `com.apple.developer.networking.multicast`. Manual
entry and scanning do not bypass Local Network policy: connecting to a LAN
address still triggers it. Refusing the camera leaves paste and manual entry
available. No microphone or Photos access is used, and no camera frame is
captured or stored. The app shows a permission-specific message only when
the API reports a policy denial. A timeout, an empty list or a path change is
reported as what it is.

`Tests/RuntimeScripts/test_link_configuration.py` checks the generated and
packaged plists and entitlements.

## 5. Two addresses: SSH, then roaming

A connection has two stages:

1. **SSH** to the host and port in the profile (verification, sign-in, and
   the no-PTY `swifttyd bootstrap`).
2. **QUIC** to the endpoint that the authenticated grant names, which is the
   Mac's configured `advertisedHost` and UDP port.

These can differ. A `.local` or LAN `advertisedHost` may not be reachable
over the route used for SSH, such as cellular or a VPN. When SSH grants an
attachment but the endpoint does not answer, the client reports a separate
stage. `RoamingFailure.endpointUnreachable`, or `.attachTimedOut`, carries
`RoamingStatus.roamingEndpoint` from the grant, and the surface shows **"SSH
connected; roaming endpoint unavailable"** with that `host:port`. It does not
blame authentication, diagnose a firewall or permission problem from a
timeout, or show tokens. The grant's endpoint is used as is: it is never
replaced by the SSH host, a discovered host, or TXT or QR data, and TLS
pinning is unchanged. One route is advertised; this document adds no
multi-route selection. The ordinary SSH shell remains a separately labelled
fallback with its own session lifetime. It is never presented as the resumed
workspace. Connectivity is never tested by sending a create request.

## 6. Acceptance evidence

| ID | Evidence |
|---|---|
| T1 | `HostProfileStoreTests` (unchanged v1 file). Manual entry is the existing editor. |
| T2, T3, T5 | `NearbyDiscoveryTests` (validation, bounds, collisions, supersession, late and withdrawn answers, error kinds); browsing starts only in `NearbyMacsView` |
| T4 | `ConnectDeviceTests` (port used, withdrawal, late updates, panel close) |
| T6 | `HostConnectionDescriptorTests`, `ConnectionCodeTests`, `ConnectDeviceTests` round trip |
| T7 | `PairingTrustTests` (unknown and known keys outside the code, substituted key, matching code, no credentials sent) |
| T8 | `PairingTrustTests` (nothing saved on failure; no password or pins in `hosts.json`); camera lifecycle in `ScanCodeView` |
| T9–T11 | `WorkspaceChooserTests`, `WorkspaceIntentTests` |
| T12 | `RoamingEndpointStageTests` |
| T14 | `test_link_configuration.py` |
| Physical, LAN | 2026-10-15, `Scripts/test-app-ui.sh` against real OpenSSH and `swifttyd`: `RoamingAppUITests` on an iPad Pro 12.9" (5th gen) and an iPhone 16 over the LAN (192.168.1.3). `ConnectToMacUITests` on the iPhone 16 covered Nearby Macs against a real `_swiftty._tcp` registration through to the chooser, a pasted code with a matching key and with another key, camera deny then allow, and Local Network denial on a fresh app identity (`RST_UI_BUNDLE_SUFFIX`). |
| T13 | 2026-10-15, iPhone 16 over Tailscale: SSH and the grant's roaming endpoint both used the VPN IP (100.84.104.15) and then the MagicDNS name (`mbp.tail11b15.ts.net`). Both `RoamingAppUITests` passed each time. The owner accepted these runs as the separately configured VPN/DNS deployment. Bonjour over cellular and NAT traversal are not claimed. |
| Camera scan | 2026-10-15, iPhone 16: `ConnectToMacUITests.testScanningTheMacPairingCodeOpensConfirmation` (`RST_UI_SCAN=1`). Scan Mac Code scanned this Mac's code as rendered by the panel's `PairingCodeView`. The confirm screen showed `mbp.local`, port 22, account `chr33s`, and both SSH host-key fingerprints (ECDSA `SHA256:Fv7tb7QA…`, ed25519 `SHA256:KR7Jr73/…`). Connect stayed disabled until the source was confirmed, and no password prompt appeared. |
| Panel | `ConnectDeviceTests`: the panel's QR, rendered to pixels and scanned with CoreImage, decodes to the exported descriptor. A real `DNSServiceRegister` resolves with `dns-sd -L` to the chosen port and TXT, and is withdrawn on stop. |

Excluded: another native window unification, renderer parity rewrites, a
cloud device directory, account or credential sync (opt-in SSH identity and
profile sync is specified separately in spec.ssh-identity.md), a pairing server,
automatic key installation, raw network scanning, firewall or router
automation, NAT traversal, built-in VPN integration, multi-route QUIC
negotiation, tablet layout-editor parity, and additional concurrent mobile
writers.
