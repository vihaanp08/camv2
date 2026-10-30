#!/bin/bash
# Builds and runs the Core/ test harness. Needs only Command Line Tools.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)/coretests"
swiftc -O -o "$OUT" "$ROOT"/CardSwap/CardSwap/Core/*.swift "$ROOT"/tests/main.swift
"$OUT"
