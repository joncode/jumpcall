#!/usr/bin/env bash
# Usage: scripts/render-formula.sh <version> <sha256> > Formula/jumpcall.rb
# Renders the Homebrew formula for a prebuilt release tarball.
set -euo pipefail
version="${1:?usage: render-formula.sh <version> <sha256>}"
sha="${2:?usage: render-formula.sh <version> <sha256>}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad version: $version" >&2; exit 1; }
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "bad sha256: $sha" >&2; exit 1; }
here="$(cd "$(dirname "$0")/.." && pwd)"
sed -e '/^# /d' -e "s/@VERSION@/$version/g" -e "s/@SHA256@/$sha/g" \
  "$here/packaging/homebrew/jumpcall.rb.in"
