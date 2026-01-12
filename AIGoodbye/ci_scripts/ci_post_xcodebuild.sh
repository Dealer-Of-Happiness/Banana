#!/bin/sh
set -e

echo "=== ci_post_xcodebuild.sh: Post-build cleanup ==="
echo "Script running at: $(date)"
echo "CI_XCODEBUILD_ACTION: $CI_XCODEBUILD_ACTION"
echo "CI_XCODEBUILD_EXIT_CODE: $CI_XCODEBUILD_EXIT_CODE"

# Log build result
if [ "$CI_XCODEBUILD_EXIT_CODE" = "0" ]; then
    echo "Build completed successfully!"
else
    echo "Build finished with exit code: $CI_XCODEBUILD_EXIT_CODE"
fi

# Any post-build cleanup can go here

echo "=== ci_post_xcodebuild.sh complete ==="
