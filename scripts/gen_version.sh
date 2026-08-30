#!/usr/bin/env bash
# Generate src/version.mojo from the workspace version in pixi.toml.
# Run before `mojo build` (or just use the `pixi run build` task).
set -euo pipefail

cd "$(dirname "$0")/.."

version="$(awk '
    /^\[/ { in_ws = ($0 ~ /^\[workspace\]/); next }
    in_ws && /^version[[:space:]]*=/ {
        line = $0
        sub(/^version[[:space:]]*=[[:space:]]*/, "", line)
        sub(/^"/, "", line)
        sub(/"$/, "", line)
        print line
        exit
    }
' pixi.toml)"

if [ -z "$version" ]; then
    echo "error: no workspace version found in pixi.toml" >&2
    exit 1
fi

cat > src/version.mojo <<EOF
# Auto-generated from pixi.toml by scripts/gen_version.sh — do not edit.
comptime VERSION = "$version"
EOF
