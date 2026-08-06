#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/Vendor/NeuralAmpModelerPlugin/NeuralAmpModeler"
PROJECT_FILE="$PROJECT_DIR/projects/NeuralAmpModeler-macOS.xcodeproj"
XCCONFIG_FILE="$PROJECT_DIR/config/NeuralAmpModeler-mac.xcconfig"
BUILD_ROOT="${UTAB_NAM_BUILD_DIR:-$ROOT_DIR/.build/vendor/nam}"
ARTIFACT_ROOT="${UTAB_NAM_ARTIFACT_DIR:-$BUILD_ROOT/artifacts}"
DERIVED_DATA_DIR="$BUILD_ROOT/DerivedData"
CONFIGURATION="${CONFIGURATION:-Release}"
TARGET="${UTAB_NAM_TARGET:-All}"
USE_MODERN_BUILD_SYSTEM="${UTAB_NAM_USE_MODERN_BUILD_SYSTEM:-NO}"

usage() {
  cat <<'EOF'
Usage: scripts/build-vendor-nam.sh [options]

Build NeuralAmpModelerPlugin from Vendor/NeuralAmpModelerPlugin using Xcode.
Artifacts are redirected to .build/vendor/nam/artifacts by default.

Options:
  --debug            Build Debug instead of Release.
  --target NAME      Xcode target to build. Default: All.
  --list-targets     Print Xcode project targets and exit.
  -h, --help         Show this help.

Environment:
  UTAB_NAM_BUILD_DIR                 Override build directory.
  UTAB_NAM_ARTIFACT_DIR              Override artifact directory.
  UTAB_NAM_TARGET                    Override target name.
  UTAB_NAM_USE_MODERN_BUILD_SYSTEM   YES or NO. Default: NO.
  CONFIGURATION                      Release or Debug.

This script does not install plug-ins into ~/Library or /Library.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      CONFIGURATION="Debug"
      ;;
    --target)
      if [[ $# -lt 2 ]]; then
        echo "error: --target requires a value" >&2
        exit 2
      fi
      TARGET="$2"
      shift
      ;;
    --list-targets)
      xcodebuild -project "$PROJECT_FILE" -list
      exit 0
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

if [[ ! -d "$PROJECT_FILE" ]]; then
  echo "error: missing $PROJECT_FILE" >&2
  echo "hint: run git submodule update --init --recursive" >&2
  exit 1
fi

mkdir -p "$ARTIFACT_ROOT/VST3"
mkdir -p "$ARTIFACT_ROOT/Components"
mkdir -p "$ARTIFACT_ROOT/Applications"
mkdir -p "$ARTIFACT_ROOT/AAX"

xcodebuild \
  -project "$PROJECT_FILE" \
  -xcconfig "$XCCONFIG_FILE" \
  -target "$TARGET" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -UseModernBuildSystem="$USE_MODERN_BUILD_SYSTEM" \
  SYMROOT="$BUILD_ROOT/build-mac" \
  VST3_PATH="$ARTIFACT_ROOT/VST3" \
  AU_PATH="$ARTIFACT_ROOT/Components" \
  APP_PATH="$ARTIFACT_ROOT/Applications" \
  AAX_PATH="$ARTIFACT_ROOT/AAX" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""

echo "NAM build directory: $BUILD_ROOT"
echo "NAM artifact directory: $ARTIFACT_ROOT"
