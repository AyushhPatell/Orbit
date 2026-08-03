#!/bin/bash
# Reminder/calendar parsing regression test. Run from orbit-core/app/ORBITMac/.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT=$(mktemp -d)
swiftc -O -o "$OUT/reminder-corpus" \
    "$DIR/reminder-corpus.swift" \
    "$DIR/../ORBITMac/OrbitUtteranceCleanup.swift"
"$OUT/reminder-corpus"
