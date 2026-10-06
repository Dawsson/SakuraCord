# Guilds and membership

[Protocol index](../PROTOCOL_BASELINE.md)

## Owners and checks

| Contract | Source | Representative checks |
| --- | --- | --- |
| Invite preview/join/leave | [DiscordRESTServerInvites.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTServerInvites.swift) | [ServerInviteContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ServerInviteContractTests.swift); [ServerInviteCaptchaTests.swift](../../App/Tests/SakuraCordAppTests/ServerInviteCaptchaTests.swift) |
| Onboarding/customization | [DiscordRESTOnboarding.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTOnboarding.swift); [AppModelGuildCustomization.swift](../../App/Sources/SakuraCord/Models/AppModelGuildCustomization.swift) | [OnboardingContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/OnboardingContractTests.swift); [GuildCustomizationTests.swift](../../App/Tests/SakuraCordAppTests/GuildCustomizationTests.swift) |
| Guide | [DiscordRESTGuildGuide.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTGuildGuide.swift); [AppModelGuildGuide.swift](../../App/Sources/SakuraCord/Models/AppModelGuildGuide.swift) | [OnboardingContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/OnboardingContractTests.swift) |
| Catalogues and members | [Gateway request builders](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordGatewaySupport.swift) | [ServerProviderContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ServerProviderContractTests.swift); [GatewayLifecycleEventTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/GatewayLifecycleEventTests.swift) |

## Invites

Preview is a read of `/invites/{code}`. Acceptance is an explicit POST to that
route with the current Gateway session and correct Join Guild or invite-embed
context. Message-card acceptance also supplies its invite-instance identity.
Preserve the preview when a sparse acceptance response omits enrichment.
`GUILD_CREATE` can arrive before or after the REST result; neither order may lose
membership. Already-member cards navigate without posting another acceptance.
Leaving is `DELETE /users/@me/guilds/{guild}` with `lurking:false`; guild owners
cannot use it. `GUILD_DELETE unavailable:true` is an outage, not a leave.

Supported invite hCaptcha retains the original body/context and permits one
replay after human completion on the same provider and Gateway session. Empty
solutions, cancellation, account replacement, another challenge or ambiguous
failure terminate that attempt. Unsupported/malformed challenges and account
restrictions retain the session safety circuit. Widget test-token verification does not establish successful handling of a live
join CAPTCHA.

Onboarding invites can enter the native membership flow. Member screening and
special guest/target flows remain delegated to Discord. Unknown catalogue or
verification state must not be reported as completed joining. A successful
membership does not require a readable channel.

Created invite links are user-requested mutations with explicit options. Cached
links are account-scoped, expire locally and are checked before reuse; they are
not evidence of membership or authorization. Use the provider request builders
for exact create/delete fields rather than extending preview behaviour implicitly.

## Onboarding and channel selection

Configuration comes from `/guilds/{guild}/onboarding`; initial answers POST to
`onboarding-responses`, later edits PUT. Welcome/member state and the existing
Gateway member query determine completion. READY's self-member records must be
available for every guild before deciding whether onboarding is needed. Unknown
membership means loading, not unfinished onboarding. Screening independently
gates sends, threads, forum creation and retries.

Choices live in the account's feature store. Restore them across navigation only
while join identity and confirmed answers still match; prune removed options.
Initial navigation through questions is local until submission. Post-join edits
are debounced and serialized per membership. A confirmation updates the baseline
without erasing newer input. After failure, read back before rolling back because
the write may have reached Discord. Optimistic roles never grant permissions.

Channel selection overlays only the relevant opt-in/favourite bits, preserving
unrelated notification settings. Category inheritance and individual choices are
distinct from Discord access permissions. Selected channels and channels with
mentions remain discoverable under the applicable filtering rules.

**Settings → Features → Channel customization** is a local preference. Off shows
all accessible channels and hides channel browsing/selection controls; applicable
role questions and required onboarding remain available. It does not erase saved
server choices or mutate Discord. Discord's separate Show All Channels setting
changes server-side filtering without erasing individual selections. Community
guilds with prompts expose Channels & Roles; those without use Browse Channels
when local channel customization is enabled. Voice/Stage channels use the same
selection policy, not an independent expansion state.

## Server Guide

Guide entry reads `new-member-welcome`, optional guild profile enrichment and
`new-member-actions`. A task records `POST /guilds/{guild}/new-member-action/{channel}`
with no body. Guide configuration PUT observed during research does not establish
an app editing surface.

Visibility depends on the applicable guild capabilities plus resources or
unfinished introductory tasks within the first seven days, not one feature flag
alone. Progress is separate from onboarding and screening. Confirm guild/member
identity on task responses; an empty progress result must not undo confirmed
`COMPLETED_HOME_ACTIONS` membership state.

Opening Guide or a resource is read-only. A visit task completes only after its
explicit navigation/history succeeds; a send task waits for a confirmed own
message. Resource previews do not complete tasks. Read resources from the beginning
of channel history through the existing provider and renderer, without a composer.
There is no established dedicated per-task Gateway progress event; refresh and
member flags supply reconciliation.

## Guild and member lifecycle

Keep raw guild/channel/role metadata sufficient to recompute permissions after
updates. Unavailable guilds retain state; ordinary deletion removes guild-scoped
state. Sparse updates preserve absent values. Permission changes must affect
retained conversations and searches without requiring a channel-list reload.

Use bounded member subscriptions/searches through the Gateway owner. Cache
identities separately from message bodies; member-list presentation should neither
scan history nor create a REST fan-out. Full profile reads are explicit/coalesced
and are not a substitute for guild member state. Check current access before
publishing a cached channel or member result after asynchronous work.
