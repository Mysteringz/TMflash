# TMflash → TMsense → TMedge verification

## Account sign-in

TMflash opens `https://algo.hkumyseat.com/tmflash/connect` using macOS
ASWebAuthenticationSession. Cloudflare's browser check and the existing algo
account/Turnstile verification run there. Authorizing the app issues a random
one-use code with a 60-second lifetime. Only the Mac holding the original
PKCE S256 verifier can exchange it for a 24-hour flasher session. The verifier
never appears in the browser URL. The callback scheme and state are checked.

The session is held only in Keychain and sent over HTTPS in the Authorization
header. TMedge stores its SHA-256 digest and account binding in a private file,
never the token. Every provisioning call checks expiry, revocation and the
account's current password fingerprint. Removing the account, changing its
password, signing out in the app or revoking it in Adoption ends access.

| Credential | Purpose | Destination |
| --- | --- | --- |
| Algo account password | Verify the person | Existing browser sign-in only |
| Expiring flasher session | Queue adoption and read approval status | Keychain → authenticated machine API |
| Wi-Fi password | Join the selected network | USB → node NVS |
| Sensor key | Authenticate node sessions and reports | USB → node NVS; matching edge key configuration |

The flasher session is never written to the board. It cannot approve devices,
read imagery, change floor placement or operate the console. No Cloudflare
service token is required.

## Adoption and verification

1. Before esptool or any USB writes, TMflash requires a valid account session
   and `tmflash.adoption.v1` preflight confirming durable storage.
2. Firmware exposes its UID over USB. TMflash queues a pending request and
   shows its UID and eight-character request code. Pending requests survive
   restarts and expire after the existing request TTL.
3. An operator signs into algo → Adoption, compares the physical request and
   types its UID/code. Only that human endpoint can admit it. The same guard
   applies to the embedded legacy console's approval endpoint.
4. Registration is persisted before the live registry changes. A new device
   has no floor, pose or owned tables. Where a device-key policy is enabled,
   its key must be enrolled before approval. Account sign-in does not replace
   telemetry authentication or change the firmware key protocol.
5. TMflash reboots and requires a fresh ACK from that boot for direct WSS.
   Adoption marks verified only while a fresh authenticated report exists.
   Silent nodes never imply empty seats.

HTTP redirects and HTML login pages are rejected. Server error bodies are
never copied into logs. Editing the console URL invalidates the Test result
and prevents sending an account credential to another console.

## Deployment

Deploy matching TMedge changes through its tested release pipeline with
production approval. `NODES_CONFIG` must point at a writable registry outside
release directories; `DATA_DIR` holds sessions, audits and report state.
`TMFLASH_TOKEN` is optional compatibility, not an account-login requirement.

Cloudflare must permit these native endpoints to reach TMedge without browser
cookies or a service token:

- `algo.hkumyseat.com/api/provision/*`
- `algo.hkumyseat.com/api/tmflash/exchange`
- `algo.hkumyseat.com/api/tmflash/logout`

Use separate path-specific Access applications with Bypass / Include Everyone
for these endpoints only. TMedge independently authenticates them. Keep the
main algo application, `/tmflash/connect`, `/api/tmflash/authorize`, Adoption,
and the console protected by their existing human policy. Unauthenticated
public preflight must return TMedge JSON 401, never Cloudflare HTML/403. See
[Cloudflare path precedence](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/app-paths/)
and [endpoint exceptions](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/common-policies/).

## Hardware baseline

The connected board `30:ed:a0:cb:f5:f8` runs TMsense 1.6 with persisted **4 fps**
and the requested site Wi-Fi. Previous complete-frame sampling measured
**3.90 fps**, with an ACK from the new boot. This existing registration
continues reporting independently of adoption sign-in. No packet layout,
NVS erasure or device-key migration is part of this change.

The account flow has local HTTP, Swift, browser and firmware fixtures.
Public browser-to-app sign-in still requires the matching production release
and path-specific Cloudflare configuration.
