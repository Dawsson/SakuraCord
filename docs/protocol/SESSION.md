# Session and authentication

[Protocol index](../PROTOCOL_BASELINE.md)

## Owners and checks

| Boundary | Source | Representative checks |
| --- | --- | --- |
| Identity and REST | [DiscordProductionBaseline.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordProductionBaseline.swift); [DiscordRESTTransport.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTTransport.swift) | [ProviderBootstrapContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ProviderBootstrapContractTests.swift); [ProviderRequestContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ProviderRequestContractTests.swift) |
| Pending credentials | [AppModelPendingAuthentication.swift](../../App/Sources/SakuraCord/Models/AppModelPendingAuthentication.swift) | [DiscordSessionAuthenticatorTests.swift](../../App/Tests/SakuraCordAppTests/DiscordSessionAuthenticatorTests.swift); [AuthenticationInstallationContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/AuthenticationInstallationContractTests.swift) |
| Main Gateway | [GatewaySession.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/GatewaySession.swift); [payload builders](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordGatewaySupport.swift) | [GatewaySessionTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/GatewaySessionTests.swift); [GatewayCodecTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/GatewayCodecTests.swift); [GatewayBacklogTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/GatewayBacklogTests.swift) |
| Service sign-in | [DiscordRESTOAuth2Authorization.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTOAuth2Authorization.swift); [AppModelIssueReports.swift](../../App/Sources/SakuraCord/Models/AppModelIssueReports.swift) | [OAuth2AuthorizationContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/OAuth2AuthorizationContractTests.swift) |
| Diagnostics | [DiscordAPIDiagnostics.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordAPIDiagnostics.swift); [DiscordDiagnosticSanitizer.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordDiagnosticSanitizer.swift) | [DiscordAPIDiagnosticsTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/DiscordAPIDiagnosticsTests.swift); [DiagnosticsSettingsTests.swift](../../App/Tests/SakuraCordAppTests/DiagnosticsSettingsTests.swift) |

## Client identity and bootstrap

The configured production baseline supplies API/Gateway version, desktop identity,
capabilities and super-properties. REST and Gateway use the same provider metadata;
app focus includes the app's relevant windows, not just the main chat window.
Installation identity and fingerprint are issued by Discord, never synthesized.
Authentication clears its fingerprint before Gateway and later production REST;
the issued installation ID can remain. Staff routing overrides are not fabricated.

READY is the live bootstrap authority. Private channels and deduplicated users
are hydrated from READY/READY_SUPPLEMENTAL, without a cold
`GET /users/@me/channels`. Production accepts the observed nested guild identity
shape as well as flat DTOs, and integer/string permission values. Partial events
preserve omitted collections. Resuming a session preserves its established state;
a fresh READY refreshes the authoritative snapshot with pending intent overlaid.

## Authentication

- Cold password login obtains installation/fingerprint metadata, submits login,
  then connects Gateway. Missing Apex identity can be resolved by the already
  required experiments request; it does not justify duplicate probes.
- Warm login reuses legitimate metadata. MFA is an explicit verification request;
  supported hCaptcha is human-completed with the bounded replay in the shared
  [attempt table](../PROTOCOL_BASELINE.md#attempt-budgets).
- QR authentication uses a remote-auth v2 socket, ephemeral RSA key and approved
  ticket exchange. Its socket never receives the account authorization token.
- Approved QR or stored credentials missing only installation identity get the
  bounded best-effort repair, then Gateway may start without that optional field.
  Do not replay login or add a pre-Gateway current-user GET.
- New credentials stay in memory until a valid `READY.user` supplies account
  identity. Import additionally requires that ID to match the selected account.
  Cancellation or failed bootstrap discards the pending credential.

### Report-service sign-in

Filing a report signs in to sakuracord.app with the first-party OAuth2 consent
sequence: `GET /oauth2/authorize` reads the consent details, then one `POST`
sends `authorize: true` with the placeholder `location_context` the official
client uses outside a channel. The app pins the application ID, `identify`
scope and `/report/callback` redirect, and rejects a service response that asks
for anything else. The returned location is parsed, never followed; its state
must match and only the one-time code reaches sakuracord.app, which exchanges it
for a bearer session kept in memory. The account credential never leaves the
provider. The sequence matches the production web bundle as of 2026-10-03
(`web.24a0dd4254453b09`). Native sign-in and report submission were also verified
against the live service; the first-party comparison remains static.

The [architecture guide](../ARCHITECTURE.md#persistence-and-privacy) owns local
import, credential storage and account-removal boundaries. Authentication must
not add unrelated analytics or user-interface prefetch requests from the official
client when SakuraCord has no consumer for them.

## Gateway lifecycle and delivery

Production uses API v9 ETF with connection-lifetime `zstd-stream`; injectable
JSON/zlib supports deterministic tests. Drain pending decompressor output even
when the compressed input is exhausted. Bound compressed input and decompressed
output before allocation growth; the latter limit is an app resource limit, not
a claimed Discord maximum. ETF integers outside JavaScript's exact range become
exact decimal strings, and `STRING_EXT` represents byte lists, not UTF-8 text.

```text
disconnected → connecting → awaitingHello → identifying/resuming → ready
                     failure → bounded backoff → connecting
                     explicit stop → stopped
```

Each Hello permits one Identify or Resume. Track heartbeat ACKs, reconnect on a
missed ACK, prefer Resume when its state remains valid, and invalidate old socket
work by generation. Explicit stop/logout never schedules reconnection. QoS and
session heartbeat metadata use the same provider identity as REST.

Use the payload builders as the outgoing operation inventory. In addition to
session, presence, member and voice operations, they include stream operations
18–22 and soundboard catalogue requests (31). Consumer dispatches include
soundboard and scheduled-event families; their contracts live in
[Voice](VOICE.md) and [Read state](READ_STATE.md).

Decode and apply events in order. Lifecycle updates reconcile guild/channel/member
catalogues without compensating REST probes. Feature-specific exceptions, such as
pending status persistence and discovery of voice streams, belong to their topic.
Do not assert that every dispatch has a zero outgoing-request budget.
Bounded delivery overflow stops the session and invalidates incomplete state;
it never silently drops an event and continues with a partial cache.

## Diagnostics

This is the authoritative payload-retention description. The
[bug-report recipe](../DEVELOPMENT.md#report-a-problem) explains the user controls.

Detailed capture retains raw REST bytes and Gateway values in a session-memory
ring bounded by entry count and estimated size. Default-on panic save also enables
that detailed retention even when the explicit detailed-capture toggle is off.
**Raw payloads can therefore exist in memory before sanitization.**

The shared output boundary redacts credentials, challenge values, user-authored
content, names, URLs, IDs, nonces, request IDs and bucket IDs before manual export
or disk output. Sanitized output is cached; raw sources are released as output
is materialized or entries are evicted/cleared. Memory release is not a promise
of cryptographic zeroization. Headers and metadata use their own allowlists.

Continuous disk capture is off by default and sanitizes each write. It keeps up
to four 64 MiB session files. Panic save writes bounded sanitized snapshots for
qualifying failures and keeps three, independently of continuous capture.
Repeated reports of the same propagated failure coalesce; normal cancellation
and intentional shutdown do not trigger saves. Clear Logs removes retained memory
and managed disk logs; enabled continuous capture resumes in a fresh file.

Connection metrics are a separate default-off option. They add timing, protocol,
reuse and scalar transport data without requests, credentials, addresses or
payload objects. Panic or detailed capture does not implicitly enable them.
Support summaries use an app-owned allowlisted schema in exported log headers.
