#!/bin/bash
# Barge-in echo/interrupt rules. Run from orbit-core/app/ORBITMac/.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT=$(mktemp -d)
swiftc -O -o "$OUT/bargein-corpus" \
    "$DIR/bargein-corpus.swift" \
    "$DIR/../ORBITMac/OrbitBargeIn.swift" \
    "$DIR/../ORBITMac/OrbitUtteranceCleanup.swift"
"$OUT/bargein-corpus"
