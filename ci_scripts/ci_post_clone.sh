#!/bin/sh
set -e

echo "=== Setting up Swift macro trust for Xcode Cloud ==="

# Skip macro fingerprint validation globally for CI environment
# This allows Swift macros from trusted packages (like LLM.swift) to run without manual approval
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

echo "✓ Macro fingerprint validation disabled"

# Pre-resolve packages with macro validation skipped
xcodebuild -resolvePackageDependencies \
  -project "$CI_WORKSPACE/AIGoodbye/AIGoodbye.xcodeproj" \
  -scheme AIGoodbye \
  -skipMacroValidation

echo "✓ Package dependencies resolved with macro validation skipped"
echo "=== Swift macro setup complete ==="
