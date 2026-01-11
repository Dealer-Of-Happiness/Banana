#!/bin/sh
set -e

# Pre-resolve packages with macro validation skipped
xcodebuild -resolvePackageDependencies \
  -project "$CI_WORKSPACE/AIGoodbye/AIGoodbye.xcodeproj" \
  -scheme AIGoodbye \
  -skipMacroValidation
