#!/bin/bash
# Floating-card policy regression test. Run from orbit-core/app/ORBITMac/.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT=$(mktemp -d)
swiftc -O -o "$OUT/card-corpus" \
    "$DIR/card-corpus.swift" \
    "$DIR/../ORBITMac/OrbitCardPolicy.swift"
"$OUT/card-corpus"
