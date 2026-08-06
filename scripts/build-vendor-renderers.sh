#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SFIZZ=1
BUILD_NAM=1
SFIZZ_ARGS=()
NAM_ARGS=()

usage() {
  cat <<'EOF'
Usage: scripts/build-vendor-renderers.sh [options]

Build vendored renderer components using their native build systems.

Options:
  --sfizz-only       Build only sfizz-ui.
  --nam-only         Build only NeuralAmpModelerPlugin.
  --debug            Build Debug instead of Release.
  --sfizz-install    Run local cmake --install for sfizz-ui.
  -h, --help         Show this help.

This script does not install plug-ins into ~/Library or /Library.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sfizz-only)
      BUILD_NAM=0
      ;;
    --nam-only)
      BUILD_SFIZZ=0
      ;;
    --debug)
      SFIZZ_ARGS+=(--debug)
      NAM_ARGS+=(--debug)
      ;;
    --sfizz-install)
      SFIZZ_ARGS+=(--install)
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$BUILD_SFIZZ" -eq 1 ]]; then
  "$ROOT_DIR/scripts/build-vendor-sfizz.sh" "${SFIZZ_ARGS[@]}"
fi

if [[ "$BUILD_NAM" -eq 1 ]]; then
  "$ROOT_DIR/scripts/build-vendor-nam.sh" "${NAM_ARGS[@]}"
fi
