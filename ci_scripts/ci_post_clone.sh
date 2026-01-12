#!/bin/sh
set -e

echo "=== ci_post_clone.sh: Setting up Swift macro trust for Xcode Cloud ==="
echo "Script running at: $(date)"
echo "HOME: $HOME"
echo "CI_WORKSPACE: $CI_WORKSPACE"
echo "PWD: $(pwd)"

# Method 1: Copy macros.json whitelist to SPM security folder
# This is the most reliable method - explicitly whitelists trusted macros
echo "Setting up SPM security folder with macro whitelist..."

# Create the SPM security directory if it doesn't exist
mkdir -p ~/Library/org.swift.swiftpm/security/

# Copy our pre-configured macros.json to the SPM security folder
# This file contains the fingerprints (git revisions) of trusted macro packages
if [ -f "$CI_WORKSPACE/ci_scripts/macros.json" ]; then
    cp "$CI_WORKSPACE/ci_scripts/macros.json" ~/Library/org.swift.swiftpm/security/
    echo "Copied macros.json to SPM security folder"
    echo "Contents:"
    cat ~/Library/org.swift.swiftpm/security/macros.json
else
    echo "WARNING: macros.json not found at $CI_WORKSPACE/ci_scripts/macros.json"
fi

# Also copy plugins.json for plugin validation
if [ -f "$CI_WORKSPACE/ci_scripts/plugins.json" ]; then
    cp "$CI_WORKSPACE/ci_scripts/plugins.json" ~/Library/org.swift.swiftpm/security/
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
