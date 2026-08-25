# Live-pet

A macOS desktop pet that carries messages between exactly two people.

An animated cat sits on top of your screen while you work. It's bonded to one
other install — permanently, via a pairing key exchanged out-of-band. When your
partner sends something, the cat reacts and their words appear in a bubble
beside it. Thirty minutes later the words are gone, from both machines, with no
trace anywhere.

**The governing idea: one pet, two windows onto it.** Not two synced cats — the
same creature, seen from two machines. Whatever happens to it is true for both
people at once. Drag it to the left and it moves left on her screen too, as if
an invisible hand picked it up. Which is what happened: your hand. Every design
question resolves toward preserving that illusion.

**Status:** spec complete. No code has been written.

**Do not write code until the user explicitly says to start.** Discussing scope,
agreeing an approach, or being asked "any more questions?" is **not**
authorization. The user says when building begins, in plain words. Ask if
unsure.

---

## Who it's for

Any two people who want a low-friction, always-visible line to each other while
working — partners, best friends, siblings, collaborators. The original use case
was a couple, but nothing in the design assumes romance and the copy must not
either.

The hard constraint is the shape, not the relationship: **exactly two Macs,
bonded to each other, permanently.** No groups. No contact list. One install
talks to one other install. The relay enforces this by refusing a third
connection to a room.

---

## Core design decisions

Settled. Treat as constraints, not suggestions.

| Area | Decision |
|---|---|
| Platform | macOS to macOS only. No iOS app in v1. |
| Pairing | One human-typable key, exchanged out-of-band, bonds two installs. |
| Delivery | **Live only.** No queueing, no offline delivery, no push notifications. |
| Storage | **No message content on disk, ever.** Messages live in memory for 30 minutes. |
| Encryption | End-to-end. The relay only ever handles ciphertext. |
| Message types | Short text, emoji, and four pet actions. No images or files. |
| Pet actions | Pet and sleep now, mirrored. Poke/feed/kiss later. Row is a list, not hardcoded. |
| Notification | Animation + speech bubble + soft sound. Bubble waits until read. |
| Position | Stays where dragged, on the **main display only**. Wandering comes after MVP. |
| Layering | Floats above fullscreen apps, present on every Space. |
| Click-through | Transparent to clicks when idle; solidifies on cursor dwell. |
| App presence | **Menu bar only, no Dock icon** (`LSUIElement`). |
| Art | PNG frame sequences. **The user is drawing these himself.** |
| Distribution | Public release. Signed and notarized. |

### Explicitly not wanted

Do not propose, design around, or quietly add:

- Message queueing or offline delivery
- Push notifications
- Any persistence of message content — no database, no cache, no log file, and
  nothing in crash reports
- Chat history, search, or scrollback beyond the 30-minute window
- Groups, multiple partners, or a contact list
- Accounts, sign-in, email addresses, or phone numbers
- Read receipts beyond the local unread state
- Image or file transfer
- Third-party Swift dependencies (see Tech stack)

---

## Architecture

```
   Mac A                     Relay                     Mac B
 ┌─────────┐              ┌─────────┐              ┌─────────┐
 │ encrypt │ ─ciphertext─▶│ forward │ ─ciphertext─▶│ decrypt │
 │ w/ pair │              │ blindly │              │  & cat  │
 │   key   │              │  NO DB  │              │ reacts  │
 └─────────┘              └─────────┘              └─────────┘
        both must be connected at the same moment
```

Two Macs can't reliably reach each other directly across the internet — home
routers block inbound connections. So a small relay sits in the middle. Its
entire job is **presence and live forwarding**: it knows two anonymous
connections share a room, and passes bytes between them.

The relay has no inbox, no database, and no disk writes. If both parties aren't
connected at the same instant, the message is never created at all.

This works only *because* delivery is presence-gated. The two decisions are
load-bearing on each other — you cannot relax "no queueing" without introducing
storage, and storage is the thing the product exists to avoid.

### Pairing key

Format: **16 Crockford base32 characters, shown in four groups of four** —
`XK7M-4F2Q-9BTZ-N3RH`. That's 80 bits of entropy. Crockford excludes I, L, O and
U, so there is nothing ambiguous to misread aloud or mistype. Input is
case-insensitive and ignores hyphens.

Derivation on both machines, independently:

```
ikm       = base32_decode(pairing_key)
room_id   = HKDF-SHA256(ikm, salt="live-pet/v1", info="room", 32 bytes) → hex
msg_key   = HKDF-SHA256(ikm, salt="live-pet/v1", info="msg",  32 bytes)
```

The app never transmits the pairing key. The relay sees only `room_id`, from
which the message key cannot be derived — so even the relay operator cannot read
anything.

### Wire protocol

WebSocket, JSON text frames. Two layers: an **outer** envelope the relay reads,
and an **inner** envelope only the two clients can read.

Outer — client to relay:

```jsonc
{ "t": "hello", "v": 1, "room": "<64-hex room_id>" }
{ "t": "msg",   "n": "<base64 nonce>", "c": "<base64 ciphertext>" }
{ "t": "ping" }
```

Outer — relay to client:

```jsonc
{ "t": "ready" }                        // hello accepted
{ "t": "peer",  "online": true|false }  // presence changed
{ "t": "msg",   "n": "...", "c": "..." }// forwarded verbatim from the peer
{ "t": "error", "code": "bad_hello" | "room_full" | "rate_limited" }
{ "t": "pong" }
```

The relay forwards `msg` frames **byte-for-byte without inspecting `c`**. It has
no reason to parse the payload and must not.

Inner — the decrypted plaintext of `c`:

```jsonc
{ "id": "<uuid>", "ts": 1735000000000, "k": "text",   "body": "back in 5" }
{ "id": "<uuid>", "ts": 1735000000000, "k": "action", "action": "pet" }
{ "id": "<uuid>", "ts": 1735000000000, "k": "move",   "x": 0.18, "y": 0.62 }
{ "id": "<uuid>", "ts": 1735000000000, "k": "state",  "x": 0.18, "y": 0.62,
  "pos_ts": 1734999000000 }
```

`action` is one of `pet`, `sleep`, `poke`, `feed`, `kiss`. Emoji are just
`text`.

`move` carries the pet's new position. `state` is sent by both clients on
entering `live` to reconcile position after a disconnect — see **Shared pet
state**.

### Shared pet state

The pet is one object with one position. Both apps render the same thing.

**Coordinates are relative, never pixels.** Position is a fraction of the screen
(`x: 0.18, y: 0.62`) referring to the pet's centre, so it lands in the same
relative spot on a 13" laptop and a 27" display. Clamp on render so the whole
assembly — cloud, pet, composer, action row — stays on screen.

**Movement syncs on drop, not during the drag.** One `move` frame when you let
go. The peer's pet then animates smoothly from its old spot to the new one, so
it reads as "someone moved it" rather than teleporting.

**Reconciling after a disconnect.** Either side can move the pet while the other
is away, so on entering `live` both clients send a `state` frame carrying their
position and the timestamp of the last local move. **Newer `pos_ts` wins**; the
loser animates to match. Simultaneous drags resolve the same way.

This is shared *state*, not history. It is a single current value, held in
memory and mirrored to `UserDefaults` for restart. Nothing accumulates.

### Connection state machine

Exactly these states. Do not invent others.

| State | Meaning | Cat shows |
|---|---|---|
| `unpaired` | No key in Keychain. First-run screen. | Placeholder / hidden |
| `connecting` | Dialing the relay, or retrying with backoff. | Idle, dimmed |
| `waiting` | Connected, peer offline. **Input disabled.** | Dozing (own animation) |
| `live` | Both online. Sending allowed. | Awake |

Transitions are driven by `ready`/`peer` frames and socket close. Reconnect uses
exponential backoff capped at ~30s. Heartbeat `ping` every 20s; two missed
`pong`s means the socket is dead — drop to `connecting`.

---

## Behaviour

### Presence — the cat's posture IS the status

There is no status text to read.

- **Awake, blinking** — peer connected (`live`). Send freely.
- **Dozing** — peer away (`waiting`). Input disabled with a plain line:
  *"Sam is away."* You cannot type into the void.

The pet is never absent, dead, or hidden. Away is a mood, not a disappearance —
it must not break the illusion that the creature is continuously alive.

**Dozing and the sleep gesture are two different animations.** They have to be:
one is a status you cannot dismiss, the other a thing you did on purpose. Same
idea, deliberately different drawings.

### Naming your partner

There are no accounts, so there is no name to look up. **You name your partner
locally**, once, during pairing — "What should I call them?" The name never
crosses the wire and the relay never learns it. This keeps the metadata surface
at zero and needs no name-exchange handshake.

### The thirty-minute window

Messages don't vanish the instant you read them. They collect in a small stack of
chat bubbles near the cat, so a quick back-and-forth reads as a conversation
rather than disconnected pop-ups. Each bubble carries its own timer; thirty
minutes later it fades and is destroyed.

The window exists only in memory. Quit the app, close the lid, or lose power and
it empties immediately — there is nothing to recover because nothing was written
down. Scroll to the edge of the last half hour and there is no "older".

**Unread handling:** an unread message keeps its bubble prominent until
acknowledged, so it can't be missed during a meeting. Once read it demotes into
the rolling stack and lives out the rest of its thirty minutes. Being away does
not extend a message's life.

### Reply input

See **Interface** below for the full layout and interaction flow.

---

## Interface

Everything stacks vertically around the cat. It is not several windows — the
whole assembly lives in the one `NSPanel`.

```
        .------------------------.
        |   thinking cloud       |    conversation, both sides
        |   grows with the chat  |
        '------o-----------------'
             o
            ( O )                     the cat - blank circle placeholder

        .------------------------.
        |  type a message...     |    input bubble
        '------------------------'
         [ pet ] [ sleep ] [ move ]   action row
```

### Idle

Only the cat is visible. No cloud, no input, no action row — an empty cloud is
clutter.

**The pet is click-through when idle** so it can never block a button
underneath. It must still be hoverable, and `ignoresMouseEvents = true` delivers
no events at all — not even hover. Resolution:

- Poll `NSEvent.mouseLocation` (~20Hz; a static read, no Accessibility
  permission needed) and compare against the pet's frame.
- After a short **dwell** (~200ms) with the cursor over the pet, set
  `ignoresMouseEvents = false`. The pet solidifies and gives a subtle highlight.
- Cursor leaves, it goes transparent again.

The dwell matters: a cursor merely passing over the pet on its way somewhere
else must not steal the click. The pet also solidifies whenever it has an unread
message, since it wants attention then.

**Verify at build time** that polling `NSEvent.mouseLocation` and
`NSEvent.modifierFlags` triggers no Accessibility prompt. If either does, drop
it and make the global hotkey the only way to reach a quiet pet.

### Opening the composer

Click the cat. The input bubble and the action row appear **together** beneath
it, and the input takes the keyboard without activating the app.

- Enter sends. **The composer stays open** for rapid back-and-forth.
- Esc closes the composer and the action row.
- Clicking away closes them too.

### The thinking cloud

Sits above the cat with trailing dots leading up to it. It holds **both sides**
of the conversation, so it reads as an exchange rather than an inbox.

- Hidden entirely when no messages are live.
- Grows with the conversation up to a cap (~1/3 of screen height). Past that,
  newest sit at the bottom and older ones scroll out of view.
- Scrolled-away messages are still alive until their 30 minutes expire.
- Individual bubbles wrap to fit their text.

### Action row

A **list**, not three hardcoded buttons — poke, feed and kiss slot in later
without a rewrite.

| Action | Mirrored? | Effect |
|---|---|---|
| Pet | Yes | Both cats purr. |
| Sleep | Yes | Both cats yawn, nap a few seconds, wake. Pure gesture. |
| Move | Yes | Drag handle. On drop, the peer's pet animates to the same relative spot. |

Mirrored actions are blocked when the peer is away, same as text — there is
nobody to mirror to.

**On move:** this mirrors. An earlier draft made it local-only; the shared-pet
model overrides that. The button is an alternative grab point to dragging the
body, useful because the pet may be click-through.

**Mirrored actions are blocked when the peer is away** — there is nobody to
mirror to. Dragging still works locally and syncs on reconnect.

---

## Tech stack

The Mac app has **zero third-party dependencies** — CryptoKit, URLSession,
SwiftUI, AVFoundation and Carbon are all in the OS. Keep it that way; a pet that
runs all day should stay small and boring. Sparkle at phase 6 is the sole
planned exception. Adding any other dependency is a decision to raise with the
user, not to make while implementing.

### Mac app

| Piece | Choice | Why |
|---|---|---|
| Language | Swift 6, strict concurrency | Catches the threading bugs an always-running app accumulates. |
| UI | SwiftUI + AppKit | SwiftUI for bubbles and input; AppKit where SwiftUI can't reach. |
| Window | Borderless `NSPanel` subclass | See below — this is what decides the stack. |
| Sprites | `TimelineView` + `Canvas` | Draws preloaded frames on a clock. Precise timing, low CPU. |
| Hotkey | Carbon `RegisterEventHotKey` | Global hotkey with **no** Accessibility permission. |
| Crypto | CryptoKit | Built in, audited, Apple-silicon accelerated. |
| Networking | `URLSessionWebSocketTask` | Built in; reconnect with exponential backoff. |
| Sound | `AVAudioPlayer` | Built in. |
| Deployment target | macOS 14+ | Three versions back; covers effectively everyone. |
| App presence | `LSUIElement = true` + `NSStatusItem` | No Dock icon, no app switcher entry. Menu bar holds Quit, Settings, pairing. |

The window configuration is load-bearing: borderless, **non-activating** (so
clicking the cat never steals focus from the user's editor), window level
`.statusBar`, collection behavior `[.canJoinAllSpaces, .fullScreenAuxiliary]`.
That combination is what lets it float over fullscreen apps and follow across
Spaces. Electron cannot do this well and would ship ~150MB plus a Chromium
process to display a cat; native is ~5MB.

**On the hotkey:** the modern API (`NSEvent.addGlobalMonitorForEvents`) requires
Accessibility permission — a system prompt granting the app the right to observe
every keystroke. For an app whose pitch is "we store nothing", asking for that on
first launch is self-defeating. Carbon's `RegisterEventHotKey` is legacy C but
needs no permission at all. This is deliberate; don't "modernise" it.

### Relay

**TypeScript on Node with `ws`.** ~150 lines: accept a socket, read `hello`, pair
it with the other socket in that room, forward frames, emit presence on
connect/disconnect. No database, no framework, no ORM.

Public release means it needs two guards it wouldn't need for one pair:

- **Room capacity of two.** A third connection to an occupied room is rejected
  with `room_full`. This is where "only two Macs" is actually enforced.
- **Rate limiting** per connection, so a room can't be used as a firehose.

Chosen over Go for deploy-anywhere portability and readability. Hosting tier
pricing needs verifying before phase 2 — worst case a $4-5/month box, and the
code is portable enough that switching hosts is an afternoon.

### Persistence exception

"Nothing on disk" governs **message content**. Three things must survive
restarts, and none of them are message data:

| Item | Where |
|---|---|
| Pairing key | macOS Keychain |
| Partner's local nickname | macOS Keychain, alongside the key |
| Cat's screen position | `UserDefaults` |

This is a clarification of the rule, not drift from it. Nothing else persists.

### Forward secrecy

v1 derives one long-term key from the pairing key. If ciphertext were recorded
over time and the key later stolen, all of it would be readable. The fix is an
X25519 handshake per connection so each session gets a throwaway key — roughly
30 extra lines with CryptoKit. Little to protect given nothing is stored, but
cheap. **Open decision at phase 2; recommendation is to do it.**

### Threat model

Defended against: a curious or compromised relay operator, passive network
observers, and anyone who steals a machine while the app is closed.

Explicitly **not** defended against: someone with access to an unlocked Mac
running the app — they can read the current window and send as you. That's the
same as any messenger and is not worth engineering around.

---

## Working mode: demo first

**Build a rough working demo before anything polished.** The user wants to see
how it *works*, not how it looks. Looks are explicitly not a concern yet.

Prove the parts that are genuinely uncertain:

- Does a floating panel behave over fullscreen apps and across Spaces?
- Does click-through with dwell-to-solidify feel right, or fight the cursor?
- Does mirrored movement actually read as *one shared pet* rather than two
  synced ones? This is the whole product thesis and it is unproven.
- Can two instances on one Mac be made to pair and talk?

Skip what is well-understood or invisible in a demo: encryption, notarization,
real art, exact expiry timing, error handling, settings UI.

### Building requires explicit permission

Settling what the demo should contain is planning, not a green light. Wait for
the user to say start. This has already been misread once — a scope answer was
taken as authorization. When in doubt, ask; the cost of asking is one sentence,
the cost of guessing is unwanted code in the repo.

Once building **is** authorized, the rule below applies.

### Ask in flight, don't gather up front

The user prefers answering questions as they arise mid-build over being blocked
by a long list beforehand. When a decision comes up while implementing, ask it
then and keep moving. Do not stall the build to assemble a questionnaire.

### Agreed demo scope — window only

Decided, **awaiting authorization to build**. One instance, no networking:

- Borderless non-activating `NSPanel`, floating above fullscreen apps, on every
  Space, main display only.
- Blank circle placeholder for the pet.
- Click-through when idle; dwell-to-solidify on cursor hover.
- Draggable, position persisted as relative coordinates, survives restart.
- Composer opens on click; action row beneath it.
- Menu bar item with Quit. No Dock icon.
- Profile namespacing (`--profile`) and the dev position offset.

Deliberately excluded: relay, pairing, encryption, mirroring, real art. Those
come once the window behaviour is proven.

### The demo is disposable

Demo code exists to answer questions, then be thrown away. Do not let it harden
into the real app by accident — no clever abstractions, no premature structure.
When the demo has taught us what it can, the phased build order below is what
actually gets built.

---

## Testing

**There is no macOS simulator.** The Mac is the target hardware; the app runs
natively. The real problem is that this is a two-machine app.

### Primary loop: two instances on one Mac

`open -n /path/to/LivePet.app` forces a second instance. Two pets side by side,
paired to each other — the best way to see the shared-pet illusion, since both
halves are visible at once.

Two things must be built for this to work, **from phase 1**:

- **Profile namespacing** — a `--profile=<id>` launch argument that namespaces
  Keychain and `UserDefaults`. Without it both instances fight over the same
  stored state and can never be strangers who pair.
- **Dev position offset** — mirrored relative coordinates put two instances on
  one screen exactly on top of each other. The second profile gets nudged aside
  in dev builds.

Relay runs locally (`cd relay && npm run dev`) with a relay URL override in the
app. Everything on one machine, no internet.

### Scripted peer

A ~40-line Node script that connects as the other side and speaks the protocol.
Build it alongside the relay in phase 2. It makes the tedious cases trivial:
flooding the cloud to hit its cap, disconnecting mid-drag to exercise `state`
reconciliation, and waiting out a 30-minute expiry.

### What genuinely needs a second Mac

One machine cannot honestly exercise:

- **Different screen sizes** — the entire reason relative coordinates exist.
- **Real network conditions** — latency, wifi drops, sleep/wake reconnects.
- **Gatekeeper**, on a machine that didn't build the app.
- **The feeling** of the pet moving when you weren't expecting it. That is the
  product, and it cannot be felt alone.

A macOS VM with a different resolution covers the screen-size case if a second
Mac isn't available.

### Automated

Swift Testing for the things that are hard to eyeball: key derivation, message
expiry, position reconciliation, the connection state machine. No UI snapshot
tests for an animated pet.

---

## Repo layout

Planned. Nothing here exists yet.

```
project.yml              XcodeGen manifest — the source of truth for the target
LivePet/
  App/                   entry point, app delegate, first-run pairing flow
  Pet/                   NSPanel, sprite engine, animation state machine
  Chat/                  bubbles, 30-minute window, reply input, hotkey
  Net/                   WebSocket client, reconnect, presence
  Crypto/                key derivation, seal/open
  Store/                 Keychain and UserDefaults wrappers
Assets/Sprites/<state>/  PNG frame sequences, one folder per state
relay/                   TypeScript relay + its own package.json
Tests/                   Swift Testing — crypto, expiry, state machine
```

## Working in this repo

Verified on this machine: Swift 6.3.3, macOS 26.5.2, Xcode command line tools
present at `/Applications/Xcode.app`.

- `xcodegen generate` after touching `project.yml` or adding files.
- `xcodebuild -scheme LivePet build` to build from the CLI.
- `cd relay && npm run dev` for the relay locally; the app takes a relay URL
  override so it can be pointed at localhost during development.
- Test the things that are hard to eyeball: key derivation, message expiry, the
  connection state machine. Don't write UI snapshot tests for an animated cat.
- Prefer deleting to accreting. This app should stay small enough to read in an
  afternoon.

---

## Sprite spec

Transparent PNG frames, one folder per state, consistent canvas size across
every frame, drawn at 3× intended on-screen size for Retina. Exact pixel
dimensions to be confirmed once window layout is settled — **don't lock these in
yet.**

| State | Triggered by | Loop | Needed by |
|---|---|---|---|
| Idle | Default resting state | Yes | 5 |
| Blink | Occasional, over idle | Once | 5 |
| Doze | Peer is away (`waiting`) | Yes | 5 |
| Sleep | The sleep gesture — transient | Yes | 5 |
| Wake | Peer comes online, or gesture ends | Once | 5 |
| Alert | Message arrives | Once, then idle | 5 |
| Purr | Receiving a pet | Yes, while stroked | 5 |
| Startle | Receiving a poke | Once | later |
| Eat | Receiving a treat | Once | later |
| Blush | Receiving a kiss | Once | later |

Startle, Eat and Blush are only needed if poke/feed/kiss get built. **Seven
states is the v1 art list.**

Doze and Sleep must be visibly different — one means "she isn't there", the
other means "she pressed a button". If they look alike, presence stops reading.

Development proceeds against a placeholder cat; real art swaps in at phase 5.

---

## Distribution

Public release, so the app must be **signed and notarized** — otherwise macOS
shows *"Apple could not verify this app is free of malware"* with only "Move to
Trash" and "Done", and the user must detour through System Settings →
Privacy & Security → Open Anyway. That is fatal for strangers.

Signing requires the **Apple Developer Program, $99/year**. There is no free
tier. Notarization is automated malware scanning, not human review — no approval
process, takes minutes. Requires the hardened runtime enabled.

**Direct download from a small website**, not the Mac App Store: the App Store
adds human review and sandboxing restrictions that fight with always-on-top
floating windows.

Release-time concern only. The app can be built and used unsigned throughout
development; signing is a build setting plus one command in the release step,
not a code change.

### Consequences of public release

- **Art must be licensed for redistribution.** The user is drawing it himself,
  which resolves this.
- **No moderation lever exists.** True E2E encryption plus zero storage means
  there is nothing to hand over in response to a report or takedown. Defensible
  for a strictly 1:1, invite-only, opt-in app, but a deliberate choice.
- **Privacy policy** should say the honest thing: we store nothing.
- **Multiple mascots become worth building.** One cat suffices for two people;
  letting each pair choose their animal is what makes it a product.

---

## Build order

Each phase produces something runnable, so the user can feel it and redirect.

1. **A cat on the screen** — floating blank circle on the main display, above
   fullscreen apps and on every Space. Click-through with dwell-to-solidify.
   Draggable, remembers position, survives restarts. Menu bar item with Quit.
   Profile namespacing and the dev offset. No networking.
2. **Two cats, one wire** — relay, pairing keys, encryption, presence. Text
   lands on the other machine. Ugly but real.
3. **The conversation** — the thinking cloud with its growth cap and scrolling,
   the composer, 30-minute rolling window, unread handling, hotkey, away state.
4. **Affection** — the action row (pet, sleep, move), emoji, sound, reaction
   animations. Poke/feed/kiss slot in here if wanted.
5. **Your cat** — swap in real art, tune animation timing, polish first-run
   pairing flow.
6. **Release** — signing, notarization, landing page, multiple mascots,
   privacy policy.

Post-MVP: the cat comes alive — wandering, napping, reacting to your typing,
appearing in the corner when you've been heads-down too long.

---

## Open questions

Tagged with the phase that needs them answered.

### Needed for phase 1

**None — phase 1 is unblocked.** Resolved: click-through with dwell, floats over
fullscreen and all Spaces, main display only, menu bar only with no Dock icon.

One thing to confirm *during* the build rather than before it: that polling
`NSEvent.mouseLocation` raises no Accessibility prompt. If it does, the global
hotkey becomes the only way to reach a quiet pet.

### Needed for phase 2

- **Unpairing** — can a pairing be broken and restarted, and does it need both
  sides to agree? Matters much more for public release than for one pair.
- **Forward secrecy** — add the per-connection X25519 handshake? Recommendation
  is yes.

### Needed for phase 3

- **Expiry clock** — do the thirty minutes start when a message is *sent* or when
  it's *read*? Send-time is more honest to "no history"; read-time guarantees a
  full half hour with it.
- **Hotkey** — which combination? `⌥Space` is comfortable but collides with
  popular launchers.
- **Message length cap** — a speech bubble stops being glanceable somewhere
  around 140 characters.

### Needed later

- **Typing indicator** [4] — should the cat show the peer is typing (ears
  twitching, looking up)? Small feature, disproportionate warmth — and the only
  thing here that leaks a little metadata to the relay.
- **Sound toggle** [4] — one setting, or per-message-type?
- **Cloud cap value** [3] — is a third of screen height right, or should the
  cloud stay smaller and more glanceable?
- **Composer while away** [3] — the composer is disabled when the peer is away.
  Should clicking the cat still open it (showing "Sam is away"), or should the
  cat simply not respond to clicks?
- **Launch at login** [5] — an always-present pet you must remember to open is a
  pet that's usually asleep.
