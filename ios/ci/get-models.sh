#!/bin/bash
# Fetches the Phonon 31m Core ML model folder (Gradium, Apache 2.0) of the release the Swift package is pinned to,
# into Podcats/Resources/Models. It is not kept in the repository (163 MB).
set -euo pipefail
cd "$(dirname "$0")/.."
dest=Podcats/Resources/Models
if [ -f "$dest/bundle.json" ]; then echo "models already there"; exit 0; fi
tmp=$(mktemp -d)
curl -sSL --fail --retry 3 -o "$tmp/m.zip" https://github.com/gradium-ai/xn-ptts/releases/download/v0.7.1/phonon-31m-en-coreml.zip
echo "058cde756a5e67bcdb986e7c45fe431d41a1a9073e68aabae314c80631a34b76  $tmp/m.zip" | shasum -a 256 -c -
unzip -q "$tmp/m.zip" -d "$tmp/x"
rm -rf "$dest"
mv "$tmp"/x/* "$dest"
test -f "$dest/bundle.json"
ls "$dest/voices" | wc -l
