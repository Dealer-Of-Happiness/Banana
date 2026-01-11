#!/bin/sh
set -e

echo "=== ci_post_clone.sh: Setting up Swift macro trust for Xcode Cloud ==="
echo "Script running at: $(date)"
echo "HOME: $HOME"
echo "CI_WORKSPACE: $CI_WORKSPACE"
echo "PWD: $(pwd)"

# Set ALL known Xcode macro/plugin trust defaults EARLY
# These settings tell Xcode to skip fingerprint validation for Swift macros
echo "Setting Xcode macro trust defaults..."

defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDEPackageSupportSkipsPluginValidation -bool YES
defaults write com.apple.dt.Xcode IDEPackageSupportSkipsPluginMacroValidation -bool YES
defaults write com.apple.dt.Xcode IDEPackageSupportDisablePluginValidation -bool YES

echo "Macro trust defaults set"

# Pre-resolve packages with macro validation skipped
# This ensures packages are downloaded and macros are pre-approved
echo "Resolving package dependencies with -skipMacroValidation and -skipPackagePluginValidation..."

xcodebuild -resolvePackageDependencies \
  -project "$CI_WORKSPACE/AIGoodbye/AIGoodbye.xcodeproj" \
  -scheme AIGoodbye \
  -skipMacroValidation \
  -skipPackagePluginValidation

echo "Package dependencies resolved"

# Verify LLM.swift package was resolved
echo "Checking resolved packages..."
if [ -f "$CI_WORKSPACE/AIGoodbye/AIGoodbye.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" ]; then
  cat "$CI_WORKSPACE/AIGoodbye/AIGoodbye.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" | grep -A 5 "LLM" || echo "LLM package info not found in resolved file"
fi

echo "=== ci_post_clone.sh complete ==="
