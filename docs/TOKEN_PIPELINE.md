# TMflash → TMsense → TMedge verification

Checked 2026-10-09. Local fixes have not been deployed to the live edge.

## The credentials and approval boundary

| Credential | Purpose | Where it goes |
| --- | --- | --- |
| Wi-Fi password | Join the selected network | USB serial → TMsense NVS |
| Sensor signing key (`TM_KEY` for the current legacy board) | Authenticate the node session and reports | USB serial → TMsense NVS; matching edge configuration |
| Provisioning token (`TMFLASH_TOKEN`) | Queue a node admission request and poll its status | TMflash Keychain → HTTPS Authorization header → console provisioning routes |
| Admin password | Approve or deny the queued request | Protected admin console routes |

The provisioning token is never flashed to the sensor. It cannot approve a
request. Approval persists a MAC registration and leaves the node unplaced;
an administrator must place it before it contributes to a seat or zone.
Already registered nodes do not require a new provisioning request to report.

## Changes

- TMflash validates the configured URL and token before flashing. Selecting
  admission without both credentials no longer silently skips admission.
- Remote endpoints require HTTPS. URL credentials, queries and fragments are
  rejected; loopback HTTP remains available for local tests and SSH tunnels.
- Requests do not follow redirects. HTTP 200 is accepted only with a JSON
  provisioning response for the requested MAC and a recognized status.
- Invalid responses and token refusals fail admission instead of claiming a
  pending request. Server error bodies cannot echo secrets into the log.
- Editing the URL or token clears the old Test result; a late response for
  previous credentials cannot overwrite it.
- TMedge rejects bearer headers with extra fields or comma-separated values,
  validates status MACs, and rejects configured tokens that cannot travel in
  the header. Both sides require 24+ printable ASCII characters without
  spaces, commas or line breaks.
- The app now points users to `console.hkumyseat.com` for provisioning.
  `sense.hkumyseat.com` is the node listener.

## Evidence

- All 61 Swift tests pass. They cover serial provisioning through pseudo-terminal nodes,
  FPS readback, admission failures, polling, malformed responses and missing
  credentials. SwiftUI snapshots show the FPS buttons in light and dark mode.
- A native Swift client exercised the real local TMedge HTTP routes: valid
  and invalid tokens, HTML and redirect rejection, pending request, status
  polling, admin approval, persisted registration and re-registration. The
  redirect destination received no request.
- The real host-compiled TMsense cloud session was refused before registration.
  After guarded admin approval it authenticated and received an acknowledgement
  for its signed report. Bearer-only approval and admin approval without the
  console mutation header were refused.
- The USB board runs TMsense 1.6. Measured complete-frame rates were about
  0.98, 1.95 and 3.91 fps for the 1, 2 and 4 fps selections; each survived a
  reboot. Invalid rates were rejected. The board was restored to 1 fps and
  joined the requested `EsanHouse` network. A final USB status read confirmed
  `wss ready`, Wi-Fi joined and a report acknowledgement `0 s ago`.
  At the user's subsequent request, the board was saved at **4 fps** and
  rebooted again. Readback confirmed 4 fps, the live edge acknowledged a
  report from the new boot, and complete-frame sampling measured **3.90 fps**.

## Live findings and remaining checks

A read-only inspection of the production environment found **no configured
`TMFLASH_TOKEN`**. The live origin refused provisioning status requests with
HTTP 401. New-node commissioning through TMflash is therefore disabled until
the production provisioning token is configured. Admin authentication and the
node listener are configured; the existing USB node's signed reporting works
independently of this token.

Unauthenticated public provisioning probes from this Mac returned HTTP 403.
The external sign-in/proxy route must also be verified with a real configured
token when commissioning is enabled. No production settings were changed.

The full edge test suite has 419 passes, five skips and one unrelated oversized-upload test failure:
`uploads: size, type and name are checked before anything is kept` fails with
`fetch failed` / a connection reset. All 41 selected provisioning, console security,
direct-node authentication, encrypted-parser and durable-ingest tests pass,
as does typecheck.

The legacy wire cross-check passes, but the encrypted-v2 cross-check cannot
pass with this TMsense checkout: its host session ignores the requested
`secure` mode and uses the legacy signing key and boot counter. TMedge expects
per-device encryption in that portion of the harness. The successful native
end-to-end test verifies the legacy path used by this physical board; it does
not establish encrypted-v2 firmware compatibility. No wire format or
encryption-policy migration was made in this task.
