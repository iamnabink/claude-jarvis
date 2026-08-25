#!/usr/bin/env bash
# Runs the JARVIS desktop overlay (transparent, click-through orb).
# Rebuilds from source first if JarvisOverlay.swift is newer than the compiled binary.
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -x JarvisOverlay ]] || [[ JarvisOverlay.swift -nt JarvisOverlay ]]; then
    echo "Building JarvisOverlay..."
    swiftc JarvisOverlay.swift -o JarvisOverlay -framework Cocoa -framework WebKit
fi

echo "Starting JARVIS desktop overlay (Ctrl+C to quit)..."
echo "Note: it connects to wss://localhost:8340/ws/voice — make sure server.py is already running."
exec ./JarvisOverlay
