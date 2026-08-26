#!/bin/bash
# Runs every phase 2 check end to end.
set -uo pipefail
cd "$(dirname "$0")"
KEY="XK7M-4F2Q-9BTZ-N3RH"
FAIL=0
pkill -f "dist/relay.js" 2>/dev/null; pkill -f "LivePet.app/Contents" 2>/dev/null; sleep 0.5
rm -f /tmp/lp-*.trace

say() { printf '\n=== %s ===\n' "$1"; }
ok()  { if [ "$1" = 0 ]; then echo "  ok    $2"; else echo "  FAIL  $2"; FAIL=1; fi; }

say "crypto (Swift against the Node reference)"
swiftc -O -target arm64-apple-macosx14.0 -o /tmp/lp-crypto \
  LivePet/Crypto/Keys.swift Tests/CryptoTests/main.swift 2>/dev/null
/tmp/lp-crypto | tail -3

say "relay guarantees"
node relay/dist/relay.js > /tmp/lp-relay.log 2>&1 &
sleep 1.2
node relay/dist/test.js | tail -3

say "client against the live relay"
swiftc -O -target arm64-apple-macosx14.0 -o /tmp/lp-net \
  LivePet/Crypto/Keys.swift LivePet/Net/Protocol.swift LivePet/Net/Client.swift \
  Tests/NetTests/main.swift 2>/dev/null
/tmp/lp-net | tail -3

say "two instances, paired, mirroring"
./LivePet.app/Contents/MacOS/LivePet --profile=b --pair="$KEY" --trace=/tmp/lp-b.trace \
  --relay=ws://localhost:8080 --drive="wait:9,quit" >/dev/null 2>&1 &
sleep 2
./LivePet.app/Contents/MacOS/LivePet --profile=a --pair="$KEY" --trace=/tmp/lp-a.trace \
  --relay=ws://localhost:8080 --drive="wait:2,text:hello,action:pet,move:0.31:0.62,wait:2,quit" >/dev/null 2>&1 &
sleep 8
grep -q "state live" /tmp/lp-a.trace; ok $? "both reach live"
grep -q "recv text hello" /tmp/lp-b.trace; ok $? "text crosses"
grep -q "recv action pet" /tmp/lp-b.trace; ok $? "action mirrors"
grep -q "recv move 0.309" /tmp/lp-b.trace; ok $? "move mirrors with relative coordinates"
grep -q "recv state" /tmp/lp-a.trace; ok $? "state exchanged on entering live"

say "a third machine is refused"
./LivePet.app/Contents/MacOS/LivePet --profile=x --pair="$KEY" --trace=/tmp/lp-x.trace --relay=ws://localhost:8080 --drive="wait:4,quit" >/dev/null 2>&1 &
./LivePet.app/Contents/MacOS/LivePet --profile=y --pair="$KEY" --trace=/tmp/lp-y.trace --relay=ws://localhost:8080 --drive="wait:5,quit" >/dev/null 2>&1 &
sleep 2
./LivePet.app/Contents/MacOS/LivePet --profile=z --pair="$KEY" --trace=/tmp/lp-z.trace --relay=ws://localhost:8080 --drive="wait:3,text:nope,quit" >/dev/null 2>&1 &
sleep 6
grep -q "drive text sent=false" /tmp/lp-z.trace; ok $? "third machine cannot send"
grep -q "state live" /tmp/lp-z.trace; [ $? -ne 0 ]; ok $? "third machine never goes live"

say "position reconciliation (newest pos_ts wins)"
NOW=$(python3 -c "import time;print(int(time.time()*1000))")
for CASE in older:1000 newer:$((NOW + 600000)); do
  LABEL="${CASE%%:*}"; TS="${CASE##*:}"
  pkill -f "LivePet.app/Contents" 2>/dev/null; sleep 0.4
  ./LivePet.app/Contents/MacOS/LivePet --profile=rc --pair="$KEY" --trace=/tmp/lp-rc.trace \
    --relay=ws://localhost:8080 --drive="wait:1,move:0.70:0.50,wait:1,pos,wait:6,pos,quit" >/dev/null 2>&1 &
  sleep 3
  node relay/dist/peer.js "$KEY" state 0.10 0.90 "$TS" >/dev/null 2>&1
  sleep 5
  FINAL=$(grep "^pos " /tmp/lp-rc.trace | tail -1)
  if [ "$LABEL" = older ]; then
    echo "$FINAL" | grep -q "0.7,0.5"; ok $? "an older pos_ts is ignored"
  else
    echo "$FINAL" | grep -q "0.1,0.9"; ok $? "a newer pos_ts wins and the pet follows"
  fi
done

say "reconnect after the relay dies and returns"
pkill -f "LivePet.app/Contents" 2>/dev/null; sleep 0.4
./LivePet.app/Contents/MacOS/LivePet --profile=rn --pair="$KEY" --trace=/tmp/lp-rn.trace \
  --relay=ws://localhost:8080 --drive="wait:30,quit" >/dev/null 2>&1 &
sleep 3
pkill -f "dist/relay.js"; sleep 4
grep -q "state connecting" /tmp/lp-rn.trace; ok $? "drops to connecting when the relay dies"
node relay/dist/relay.js > /tmp/lp-relay2.log 2>&1 &
sleep 10
[ "$(grep -c 'state waiting' /tmp/lp-rn.trace)" -ge 2 ]; ok $? "reconnects once the relay returns"
pkill -f "LivePet.app/Contents" 2>/dev/null

say "read-time expiry clock"
pkill -f "LivePet.app/Contents" 2>/dev/null; sleep 0.4
rm -f /tmp/lp-read.trace
./LivePet.app/Contents/MacOS/LivePet --profile=rd --pair="$KEY" --trace=/tmp/lp-read.trace \
  --relay=ws://localhost:8080 --expiry=5 \
  --drive="wait:2,msgs,wait:8,msgs,open,wait:1,msgs,wait:7,msgs,quit" >/dev/null 2>&1 &
sleep 3
node relay/dist/peer.js "$KEY" text "does this survive" >/dev/null 2>&1 &
sleep 16
pkill -f "dist/peer.js" 2>/dev/null
# ttl is 5s, yet the message must still be there 8s later because nobody read it.
sed -n '2p' <(grep "^msgs " /tmp/lp-read.trace) | grep -q "total=1 parked=1"
ok $? "an unread message parks past its ttl instead of expiring"
sed -n '3p' <(grep "^msgs " /tmp/lp-read.trace) | grep -q "total=1 parked=0"
ok $? "opening the cloud starts its clock"
sed -n '4p' <(grep "^msgs " /tmp/lp-read.trace) | grep -q "total=0"
ok $? "it expires a full ttl after being read, not after arriving"

say "away: the pet stirs, nothing opens"
pkill -f "LivePet.app/Contents" 2>/dev/null; sleep 0.4
rm -f /tmp/lp-away.trace
./LivePet.app/Contents/MacOS/LivePet --profile=aw --pair="$KEY" --trace=/tmp/lp-away.trace \
  --relay=ws://localhost:8080 --drive="wait:2,open,wait:1,ui,quit" >/dev/null 2>&1 &
sleep 5
grep -q "drive open opened=false" /tmp/lp-away.trace; ok $? "opening is refused while the peer is away"
grep -q "^stir" /tmp/lp-away.trace; ok $? "the pet stirs instead"
grep -q "ui expanded=false" /tmp/lp-away.trace; ok $? "nothing opens"

say "peer leaves mid-conversation"
pkill -f "LivePet.app/Contents" 2>/dev/null; sleep 0.4
rm -f /tmp/lp-mid.trace
node relay/dist/peer.js "$KEY" listen >/dev/null 2>&1 &
sleep 1
./LivePet.app/Contents/MacOS/LivePet --profile=md --pair="$KEY" --trace=/tmp/lp-mid.trace \
  --relay=ws://localhost:8080 --drive="wait:2,pin,ui,wait:6,ui,quit" >/dev/null 2>&1 &
sleep 4
pkill -f "dist/peer.js" 2>/dev/null
sleep 6
grep "^ui " /tmp/lp-mid.trace | tail -1 | grep -q "expanded=true"
ok $? "a pinned assembly stays open when the peer leaves"
grep "^ui " /tmp/lp-mid.trace | tail -1 | grep -q "canSend=false"
ok $? "but the composer is disabled"

pkill -f "LivePet.app/Contents" 2>/dev/null; pkill -f "dist/relay.js" 2>/dev/null
say "relay log must contain no room ids"
grep -qE "[0-9a-f]{64}" /tmp/lp-relay.log; [ $? -ne 0 ]; ok $? "no room id leaked into logs"

echo
[ "$FAIL" = 0 ] && echo "phases 2 and 3 verified" || echo "SOME CHECKS FAILED"
exit $FAIL
