#!/usr/bin/env bash
#
# Prepare the native libraries the graphics stack needs.
#
# Two obligations, both documented in docs/13-spike-results.md:
#
#   1. Odin vendors a compiled wgpu-native only for Windows, so macOS and Linux
#      builds must supply their own. The Homebrew package is deliberately not
#      used: its build reports version 0.0.0.0 from wgpuGetVersion(), which
#      Odin's bindings reject even when the formula version matches.
#
#   2. Odin ships stb as C sources that must be compiled before
#      vendor:stb/truetype will link.
#
# Both write into the Odin installation rather than the project tree, so this
# must be re-run after upgrading Odin.

set -euo pipefail

# Must match BINDINGS_VERSION in the pinned Odin release's vendor/wgpu.
WGPU_VERSION="29.0.1.1"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v odin >/dev/null 2>&1; then
	echo "error: odin is not on PATH" >&2
	exit 127
fi

ODIN_ROOT="$(odin root)"
VENDOR_DIR="${ODIN_ROOT}/vendor/wgpu/lib"

case "$(uname -s)" in
	Darwin) PLATFORM="macos" ;;
	Linux)  PLATFORM="linux" ;;
	*)
		echo "error: unsupported platform $(uname -s)" >&2
		exit 2
		;;
esac

# Odin's bindings spell ARM as "aarch64", not "arm64".
case "$(uname -m)" in
	arm64|aarch64) ARCH="aarch64" ;;
	x86_64)        ARCH="x86_64" ;;
	*)
		echo "error: unsupported architecture $(uname -m)" >&2
		exit 2
		;;
esac

# --- stb -------------------------------------------------------------------

if [[ -f "${ODIN_ROOT}/vendor/stb/lib/stb_truetype.a" ]]; then
	echo "stb libraries already built"
else
	echo "building Odin's vendored stb libraries"
	make -C "${ODIN_ROOT}/vendor/stb/src" >/dev/null
	echo "built stb libraries"
fi

# --- wgpu-native -----------------------------------------------------------

TARGET="wgpu-${PLATFORM}-${ARCH}-release"
DEST="${VENDOR_DIR}/${TARGET}/lib"

if [[ -f "${DEST}/libwgpu_native.a" ]]; then
	echo "wgpu-native ${WGPU_VERSION} already present"
	exit 0
fi

URL="https://github.com/gfx-rs/wgpu-native/releases/download/v${WGPU_VERSION}/${TARGET}.zip"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "fetching ${URL}"
if ! curl -fsSL -o "${WORK}/wgpu.zip" "${URL}"; then
	echo "error: could not download ${URL}" >&2
	exit 1
fi

unzip -q -o "${WORK}/wgpu.zip" -d "${WORK}/extracted"

mkdir -p "${DEST}"
find "${WORK}/extracted" -name 'libwgpu_native.*' -exec cp {} "${DEST}/" \;

if [[ ! -f "${DEST}/libwgpu_native.a" ]]; then
	echo "error: the archive did not contain libwgpu_native.a" >&2
	exit 1
fi

echo "installed wgpu-native ${WGPU_VERSION} to ${DEST}"
echo
echo "note: this writes into the Odin installation, not the project tree."
echo "      re-run after upgrading Odin."
