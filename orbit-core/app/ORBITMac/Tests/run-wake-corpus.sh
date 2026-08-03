#!/bin/bash
# Wake-phrase regression test. Run from orbit-core/app/ORBITMac/.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT=$(mktemp -d)
swiftc -O -o "$OUT/wake-corpus" \
    "$DIR/wake-corpus.swift" \
    "$DIR/../ORBITMac/OrbitWakePhraseMatcher.swift" \
    "$DIR/../ORBITMac/OrbitVoiceIntentHelpers.swift"
"$OUT/wake-corpus"
