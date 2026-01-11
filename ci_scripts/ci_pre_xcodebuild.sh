#!/bin/sh
set -e

echo "=== ci_pre_xcodebuild.sh: Setting up Swift macro trust before build ==="
echo "HOME: $HOME"
echo "CI_WORKSPACE: $CI_WORKSPACE"
echo "CI_XCODE_PROJECT: $CI_XCODE_PROJECT"
echo "CI_XCODE_SCHEME: $CI_XCODE_SCHEME"

# Set ALL known Xcode macro/plugin trust defaults
# These must be set right before xcodebuild runs to have any chance of being read
echo "Setting Xcode macro trust defaults..."

# Primary macro validation skip flags
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES

# Package support plugin/macro validation skip (Xcode 15.3+)
defaults write com.apple.dt.Xcode IDEPackageSupportSkipsPluginValidation -bool YES
defaults write com.apple.dt.Xcode IDEPackageSupportSkipsPluginMacroValidation -bool YES

# Additional flags that might help
defaults write com.apple.dt.Xcode IDEPackageSupportDisablePluginValidation -bool YES

# Verify settings were written
echo "Verifying defaults:"
defaults read com.apple.dt.Xcode IDESkipMacroFingerprintValidation 2>/dev/null || echo "  IDESkipMacroFingerprintValidation: not readable"
defaults read com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation 2>/dev/null || echo "  IDESkipPackagePluginFingerprintValidation: not readable"
defaults read com.apple.dt.Xcode IDEPackageSupportSkipsPluginMacroValidation 2>/dev/null || echo "  IDEPackageSupportSkipsPluginMacroValidation: not readable"

# List all Xcode defaults that contain "macro" or "plugin" (for debugging)
echo "All macro/plugin related Xcode defaults:"
defaults read com.apple.dt.Xcode 2>/dev/null | grep -i -E "(macro|plugin)" || echo "  No macro/plugin defaults found"

echo "=== Macro trust setup complete ==="
