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

pkill -f "LivePet.app/Contents" 2>/dev/null; pkill -f "dist/relay.js" 2>/dev/null
say "relay log must contain no room ids"
grep -qE "[0-9a-f]{64}" /tmp/lp-relay.log; [ $? -ne 0 ]; ok $? "no room id leaked into logs"

echo
[ "$FAIL" = 0 ] && echo "phase 2 verified" || echo "SOME CHECKS FAILED"
exit $FAIL
