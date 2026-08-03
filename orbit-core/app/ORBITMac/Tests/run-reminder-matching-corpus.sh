#!/bin/bash
# Reminder duplicate + completion matching. Run from orbit-core/app/ORBITMac/.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT=$(mktemp -d)
swiftc -O -o "$OUT/reminder-matching-corpus" \
    "$DIR/reminder-matching-corpus.swift" \
    "$DIR/../ORBITMac/OrbitReminderMatching.swift"
"$OUT/reminder-matching-corpus"
