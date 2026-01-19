#!/bin/bash
# AI Goodbye Desktop - macOS Build Script
# Run this on a Mac to build the macOS installer

set -e

echo "========================================"
echo "AI Goodbye - macOS Build"
echo "========================================"
echo ""

# Check prerequisites
echo "Checking prerequisites..."

# Check Node.js
if command -v node &> /dev/null; then
    echo "Node.js: $(node --version)"
else
    echo "ERROR: Node.js is not installed"
    echo "Please install Node.js from https://nodejs.org/"
    exit 1
fi

# Check Rust
if command -v rustc &> /dev/null; then
    echo "Rust: $(rustc --version)"
else
    echo "ERROR: Rust is not installed"
    echo "Please install Rust from https://rustup.rs/"
    exit 1
fi

# Check Python
if command -v python3 &> /dev/null; then
    echo "Python: $(python3 --version)"
else
    echo "ERROR: Python is not installed"
    echo "Please install Python from https://python.org/"
    exit 1
fi

echo ""
echo "Installing npm dependencies..."
npm install

echo ""
echo "Bundling Python backend..."
npm run bundle:python

echo ""
echo "Building Tauri application..."

# Build for the current architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    echo "Building for Apple Silicon (arm64)..."
    npm run build:mac-arm
else
    echo "Building for Intel (x86_64)..."
    npm run build:mac-intel
fi

# Optionally build universal binary
if [ "$1" = "--universal" ]; then
    echo ""
    echo "Building universal binary..."
    npm run build:mac
fi

echo ""
echo "========================================"
echo "Build Complete!"
echo "========================================"
echo ""
echo "DMG location:"
echo "  src-tauri/target/release/bundle/dmg/"
echo ""
echo "App bundle location:"
echo "  src-tauri/target/release/bundle/macos/"
echo ""

# Code signing reminder
echo "IMPORTANT: For distribution, you should code sign the app:"
echo "  1. Get an Apple Developer certificate"
echo "  2. Sign with: codesign --deep --force --sign 'Developer ID' 'AI Goodbye.app'"
echo "  3. Notarize with: xcrun notarytool submit 'AI Goodbye.dmg' --wait"
