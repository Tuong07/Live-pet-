# Window-behaviour demo

Disposable. Exists to answer one question: does a floating `NSPanel` behave the
way the spec assumes? No relay, no pairing, no encryption, no mirroring, no art.

```
./build.sh && open -n LivePetDemo.app
```

Quit from the `◍` menu bar item.

## Flags

| Flag | Effect |
|---|---|
| `--profile=<id>` | Namespaces stored state and applies the dev position offset. Two instances need different profiles. |
| `--expiry=<seconds>` | Message lifetime, default 1800. Use something small to watch expiry. |
| `--diag` | Prints window state, exercises the state machine headlessly, exits. |

## Two instances

```
open -n LivePetDemo.app
open -n LivePetDemo.app --args --profile=b
```

They do not talk to each other yet — that is phase 2. Separate profiles just
prove the stored state is properly namespaced.

## Beyond the agreed scope

Two menu items are dev affordances, not product features: **Simulate incoming
message** (there is no peer yet, and without it the cloud, the unread state and
the alert reaction cannot be seen at all) and **Reset position**.
