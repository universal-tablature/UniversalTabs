#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT_DIR/Vendor/sfizz-ui"
SFIZZ_LIBRARY_DIR="$SRC_DIR/library"
SFIZZ_LIBRARY_PATCH="$ROOT_DIR/Vendor/patches/sfizz-library-macos-clang.patch"
BUILD_DIR="${UTAB_SFIZZ_BUILD_DIR:-$ROOT_DIR/.build/vendor/sfizz-ui}"
INSTALL_DIR="${UTAB_SFIZZ_INSTALL_DIR:-$BUILD_DIR/install}"
CONFIGURATION="${CONFIGURATION:-Release}"
MACOS_DEPLOYMENT_TARGET="${UTAB_MACOS_DEPLOYMENT_TARGET:-}"

PLUGIN_AU="ON"
PLUGIN_VST3="ON"
PLUGIN_LV2="OFF"
PLUGIN_LV2_UI="OFF"
PLUGIN_PUREDATA="OFF"
DO_CONFIGURE=1
DO_BUILD=1
DO_INSTALL=0
CMAKE_EXTRA_ARGS=()

case "$(uname -s):$(uname -m)" in
  Darwin:arm64)
    # sfizz 1.2.x treats PROJECT_SYSTEM_PROCESSOR matching "arm.*" as 32-bit
    # ARM and adds -mfpu/-mfloat-abi, which are invalid for Apple Silicon.
    # Use aarch64 to keep the architecture meaning without triggering that
    # legacy 32-bit ARM flag path.
    CMAKE_EXTRA_ARGS+=(-DPROJECT_SYSTEM_PROCESSOR=aarch64)
    if [[ -z "$MACOS_DEPLOYMENT_TARGET" ]]; then
      MACOS_DEPLOYMENT_TARGET="11.0"
    fi
    ;;
esac

usage() {
  cat <<'EOF'
Usage: scripts/build-vendor-sfizz.sh [options]

Build sfizz-ui from Vendor/sfizz-ui with CMake.

Options:
  --configure-only   Configure CMake but do not build.
  --build-only       Build an existing CMake build directory without configuring.
  --install          Run cmake --install into .build/vendor/sfizz-ui/install.
  --debug            Build Debug instead of Release.
  --no-au            Disable AudioUnit plug-in build.
  --no-vst3          Disable VST3 plug-in build.
  --lv2              Enable LV2 plug-in build.
  --puredata         Enable Pure Data plug-in build.
  -h, --help         Show this help.

Environment:
  UTAB_SFIZZ_BUILD_DIR    Override build directory.
  UTAB_SFIZZ_INSTALL_DIR  Override install directory.
  UTAB_MACOS_DEPLOYMENT_TARGET
                           Override macOS deployment target. Defaults to 11.0
                           on Apple Silicon.
  CONFIGURATION           Release or Debug.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configure-only)
      DO_BUILD=0
      ;;
    --build-only)
      DO_CONFIGURE=0
      ;;
    --install)
      DO_INSTALL=1
      ;;
    --debug)
      CONFIGURATION="Debug"
      ;;
    --no-au)
      PLUGIN_AU="OFF"
      ;;
    --no-vst3)
      PLUGIN_VST3="OFF"
      ;;
    --lv2)
      PLUGIN_LV2="ON"
      ;;
    --puredata)
      PLUGIN_PUREDATA="ON"
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

if [[ ! -f "$SRC_DIR/CMakeLists.txt" ]]; then
  echo "error: missing $SRC_DIR/CMakeLists.txt" >&2
  echo "hint: run git submodule update --init --recursive" >&2
  exit 1
fi

if [[ ! -f "$SFIZZ_LIBRARY_DIR/CMakeLists.txt" ]]; then
  echo "error: missing $SFIZZ_LIBRARY_DIR/CMakeLists.txt" >&2
  echo "hint: run git submodule update --init --recursive" >&2
  exit 1
fi

if [[ ! -f "$SFIZZ_LIBRARY_PATCH" ]]; then
  echo "error: missing $SFIZZ_LIBRARY_PATCH" >&2
  exit 1
fi

if git -C "$SFIZZ_LIBRARY_DIR" apply --check "$SFIZZ_LIBRARY_PATCH" >/dev/null 2>&1; then
  echo "applying sfizz library compatibility patch: $SFIZZ_LIBRARY_PATCH"
  git -C "$SFIZZ_LIBRARY_DIR" apply "$SFIZZ_LIBRARY_PATCH"
elif git -C "$SFIZZ_LIBRARY_DIR" apply --reverse --check "$SFIZZ_LIBRARY_PATCH" >/dev/null 2>&1; then
  echo "sfizz library compatibility patch already applied"
else
  echo "error: sfizz library compatibility patch does not apply cleanly" >&2
  echo "hint: inspect Vendor/sfizz-ui/library for local changes or updated upstream code" >&2
  exit 1
fi

GENERATOR_ARGS=()
if command -v ninja >/dev/null 2>&1; then
  GENERATOR_ARGS=(-G Ninja)
fi

if [[ "$DO_CONFIGURE" -eq 1 ]]; then
  if [[ "${#GENERATOR_ARGS[@]}" -gt 0 ]]; then
    CMAKE_EXTRA_ARGS+=("${GENERATOR_ARGS[@]}")
  fi
  if [[ -n "$MACOS_DEPLOYMENT_TARGET" ]]; then
    CMAKE_EXTRA_ARGS+=(-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET")
  fi

  cmake -S "$SRC_DIR" -B "$BUILD_DIR" "${CMAKE_EXTRA_ARGS[@]}" \
    -DCMAKE_BUILD_TYPE="$CONFIGURATION" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DSFIZZ_GIT_SUBMODULE_CHECK=OFF \
    -DPLUGIN_AU="$PLUGIN_AU" \
    -DPLUGIN_VST3="$PLUGIN_VST3" \
    -DPLUGIN_LV2="$PLUGIN_LV2" \
    -DPLUGIN_LV2_UI="$PLUGIN_LV2_UI" \
    -DPLUGIN_PUREDATA="$PLUGIN_PUREDATA"
fi

if [[ "$DO_BUILD" -eq 1 ]]; then
  cmake --build "$BUILD_DIR" --config "$CONFIGURATION"
fi

if [[ "$DO_INSTALL" -eq 1 ]]; then
  cmake --install "$BUILD_DIR" --config "$CONFIGURATION"
fi

echo "sfizz-ui build directory: $BUILD_DIR"
echo "sfizz-ui install directory: $INSTALL_DIR"
