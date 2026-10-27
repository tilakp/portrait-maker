#!/bin/bash
# Downloads Apple's Core ML build of Depth Anything V2 Small (Apache-2.0) at a fixed
# commit, checks the SHA-256 of each file, and compiles it to Models/DepthAnything.mlmodelc.
# The model is not stored in the repository. A second run uses the cached copy.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="apple/coreml-depth-anything-v2-small"
COMMIT="cfef6f6f2a70783dedc0bfae40cecbc2052285d3"
PACKAGE="DepthAnythingV2SmallF16.mlpackage"
OUT="Models"
FILES=(
    "Manifest.json"
    "Data/com.apple.CoreML/model.mlmodel 44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042"
    "Data/com.apple.CoreML/weights/weight.bin fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed"
)

[ -d "$OUT/DepthAnything.mlmodelc" ] && exit 0

mkdir -p "$OUT"
for entry in "${FILES[@]}"; do
    read -r path sha <<< "$entry"
    target="$OUT/$PACKAGE/$path"
    mkdir -p "$(dirname "$target")"
    curl -fsSL -o "$target" "https://huggingface.co/$REPO/resolve/$COMMIT/$PACKAGE/$path"
    if [ -n "${sha:-}" ]; then
        echo "$sha  $target" | shasum -a 256 -c --quiet
    fi
done

xcrun coremlcompiler compile "$OUT/$PACKAGE" "$OUT"
mv "$OUT/DepthAnythingV2SmallF16.mlmodelc" "$OUT/DepthAnything.mlmodelc"
echo "Compiled $OUT/DepthAnything.mlmodelc"
