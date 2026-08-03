#!/bin/bash
# Semantic endpointing regression test. Run from orbit-core/app/ORBITMac/.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT=$(mktemp -d)
swiftc -O -o "$OUT/completeness-corpus" \
    "$DIR/completeness-corpus.swift" \
    "$DIR/../ORBITMac/OrbitUtteranceCompleteness.swift" \
    "$DIR/../ORBITMac/OrbitUtteranceCleanup.swift"
"$OUT/completeness-corpus"
