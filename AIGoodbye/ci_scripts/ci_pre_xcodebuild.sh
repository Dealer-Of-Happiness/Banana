#!/bin/sh
set -e

echo "=== ci_pre_xcodebuild.sh: Verifying Swift macro trust before build ==="
echo "Script running at: $(date)"
echo "CI_XCODEBUILD_ACTION: $CI_XCODEBUILD_ACTION"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "SCRIPT_DIR: $SCRIPT_DIR"

# Ensure SPM security folder exists and has the whitelist files
echo "Verifying SPM security configuration..."

SPM_SECURITY_DIR=~/Library/org.swift.swiftpm/security/

if [ -d "$SPM_SECURITY_DIR" ]; then
    echo "SPM security folder exists"
    echo "Contents:"
    ls -la "$SPM_SECURITY_DIR"
else
    echo "SPM security folder not found, creating it..."
    mkdir -p "$SPM_SECURITY_DIR"

    # Copy whitelist files if they exist
    if [ -f "$SCRIPT_DIR/macros.json" ]; then
        cp "$SCRIPT_DIR/macros.json" "$SPM_SECURITY_DIR"
        echo "Copied macros.json"
    fi

    if [ -f "$SCRIPT_DIR/plugins.json" ]; then
        cp "$SCRIPT_DIR/plugins.json" "$SPM_SECURITY_DIR"
        echo "Copied plugins.json"
    fi
fi

# Verify Xcode defaults are set
echo "Verifying Xcode macro trust defaults..."
defaults read com.apple.dt.Xcode IDESkipMacroFingerprintValidation 2>/dev/null || echo "IDESkipMacroFingerprintValidation not set"
defaults read com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation 2>/dev/null || echo "IDESkipPackagePluginFingerprintValidation not set"

# Re-apply defaults as a safety measure
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES

echo "=== ci_pre_xcodebuild.sh complete ==="
