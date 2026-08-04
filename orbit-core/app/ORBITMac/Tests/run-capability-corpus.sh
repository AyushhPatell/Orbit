#!/bin/bash
# Capability gate coverage. Run from orbit-core/app/ORBITMac/.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT=$(mktemp -d)
swiftc -O -o "$OUT/capability-corpus" \
    "$DIR/capability-corpus.swift" \
    "$DIR/../ORBITMac/OrbitCapabilities.swift"
"$OUT/capability-corpus"
