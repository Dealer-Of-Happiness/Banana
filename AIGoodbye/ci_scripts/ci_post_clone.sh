#!/bin/sh
set -e

echo "=== ci_post_clone.sh: Setting up Swift macro trust for Xcode Cloud ==="
echo "Script running at: $(date)"
echo "HOME: $HOME"
echo "CI_WORKSPACE: $CI_WORKSPACE"
echo "PWD: $(pwd)"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "SCRIPT_DIR: $SCRIPT_DIR"

# Method 1: Copy macros.json whitelist to SPM security folder
# This is the most reliable method - explicitly whitelists trusted macros
echo "Setting up SPM security folder with macro whitelist..."

# Create the SPM security directory if it doesn't exist
mkdir -p ~/Library/org.swift.swiftpm/security/

# Copy our pre-configured macros.json to the SPM security folder
# This file contains the fingerprints (git revisions) of trusted macro packages
if [ -f "$SCRIPT_DIR/macros.json" ]; then
    cp "$SCRIPT_DIR/macros.json" ~/Library/org.swift.swiftpm/security/
    echo "Copied macros.json to SPM security folder"
    echo "Contents:"
    cat ~/Library/org.swift.swiftpm/security/macros.json
else
    echo "WARNING: macros.json not found at $SCRIPT_DIR/macros.json"
fi

# Also copy plugins.json for plugin validation
if [ -f "$SCRIPT_DIR/plugins.json" ]; then
    cp "$SCRIPT_DIR/plugins.json" ~/Library/org.swift.swiftpm/security/
    echo "Copied plugins.json to SPM security folder"
else
    echo "WARNING: plugins.json not found"
fi

# Method 2: Set Xcode defaults as a fallback
# This tells Xcode to skip fingerprint validation entirely
echo "Setting Xcode macro trust defaults as fallback..."

defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES

echo "Xcode defaults set"

# Verify the security folder contents
echo "SPM security folder contents:"
ls -la ~/Library/org.swift.swiftpm/security/ || echo "Could not list security folder"

echo "=== ci_post_clone.sh complete ==="
