#!/usr/bin/env bash
#
# Developer command surface for Norn.
#
# docs/10-development.md requires CI and developers to call the same underlying
# commands. Every command in that document routes through this script.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT}/build"
ARTIFACTS_DIR="${ROOT}/artifacts"

# The pinned compiler release. A mismatch is a warning rather than an error so
# that a contributor can investigate a new release without editing the script.
PINNED_ODIN_VERSION="$(cat "${ROOT}/.odin-version")"

COLLECTION=(-collection:src="${ROOT}/src")

usage() {
	cat <<'EOF'
Usage: scripts/norn.sh <command> [arguments]

Commands:
  build [profile]     Build the norn executable (debug|release|sanitize|profile)
  run [arguments]     Build in debug and run the executable
  test [package]      Run tests for one package, or every package
  check               Type-check every package without producing binaries
  format-check        Verify formatting is unchanged
  spike <name> [args]  Build and run a phase-zero spike (graphics)
  clean               Remove build and artifact directories
EOF
}

require_odin() {
	if ! command -v odin >/dev/null 2>&1; then
		echo "error: odin is not on PATH" >&2
		echo "hint: brew install odin" >&2
		exit 127
	fi
	local actual
	actual="$(odin version | grep -oE 'dev-[0-9]{4}-[0-9]{2}' || true)"
	if [[ -n "${actual}" && "${actual}" != "${PINNED_ODIN_VERSION}" ]]; then
		echo "warning: odin ${actual} differs from pinned ${PINNED_ODIN_VERSION}" >&2
	fi
}

# Flags per docs/10 build profiles. Bounds, container integrity, path safety,
# and resource-limit checks stay enabled in every profile, so no profile
# disables the bounds checking that enforces them.
profile_flags() {
	case "${1}" in
		debug)    echo "-debug" ;;
		release)  echo "-o:speed" ;;
		sanitize) echo "-debug -sanitize:address" ;;
		profile)  echo "-o:speed -debug" ;;
		*)
			echo "error: unknown profile '${1}'" >&2
			exit 2
			;;
	esac
}

# Packages that contain tests, in dependency order.
test_packages() {
	echo "core model codec replay analysis export render ui app importers"
}

test_package_path() {
	case "${1}" in
		core)  echo "tests/core" ;;
		model) echo "tests/model" ;;
		codec)  echo "tests/codec" ;;
		replay) echo "tests/replay" ;;
		analysis) echo "tests/analysis" ;;
		export) echo "tests/export" ;;
		render) echo "tests/render" ;;
		ui)     echo "tests/ui" ;;
		app)    echo "tests/app" ;;
		importers) echo "tests/importers" ;;
		*)
			echo "error: unknown test package '${1}'" >&2
			exit 2
			;;
	esac
}

cmd_build() {
	require_odin
	local profile="${1:-debug}"
	local flags
	flags="$(profile_flags "${profile}")"
	mkdir -p "${BUILD_DIR}"
	# shellcheck disable=SC2086
	odin build "${ROOT}/src/main" "${COLLECTION[@]}" ${flags} \
		-out:"${BUILD_DIR}/norn"
	echo "built ${BUILD_DIR}/norn (${profile})"
}

cmd_run() {
	cmd_build debug
	"${BUILD_DIR}/norn" "$@"
}

cmd_test() {
	require_odin
	mkdir -p "${ARTIFACTS_DIR}"
	local packages
	local all=0
	if [[ $# -gt 0 ]]; then
		packages="$*"
	else
		packages="$(test_packages)"
		all=1
	fi
	local failed=0
	for package in ${packages}; do
		local path
		path="$(test_package_path "${package}")"
		if [[ ! -d "${ROOT}/${path}" ]]; then
			continue
		fi
		echo "== ${package}"
		if ! odin test "${ROOT}/${path}" "${COLLECTION[@]}" \
			-out:"${ARTIFACTS_DIR}/test_${package}"; then
			failed=1
		fi
	done

	# The CLI contract — exit codes, stream separation, argument parsing — is
	# only observable from the built binary, so it is checked separately.
	if [[ "${all}" == 1 ]]; then
		echo "== cli"
		cmd_build debug >/dev/null || return 1
		if ! "${ROOT}/scripts/test-cli.sh"; then
			failed=1
		fi
	fi

	return "${failed}"
}

cmd_check() {
	require_odin
	local failed=0
	for package in "${ROOT}"/src/*/ "${ROOT}"/src/trace/*/; do
		[[ -d "${package}" ]] || continue
		# A directory holding only subpackages has no .odin files of its own.
		compgen -G "${package}*.odin" >/dev/null || continue
		# Library packages have no main; only src/main defines an entry point.
		local entry_flag="-no-entry-point"
		if [[ "${package}" == */src/main/ ]]; then
			entry_flag=""
		fi
		# shellcheck disable=SC2086
		if ! odin check "${package}" "${COLLECTION[@]}" ${entry_flag}; then
			failed=1
		fi
	done
	return "${failed}"
}

cmd_format_check() {
	require_odin
	if ! command -v odinfmt >/dev/null 2>&1; then
		echo "warning: odinfmt is not installed; skipping format check" >&2
		return 0
	fi
	odinfmt -l "${ROOT}/src" "${ROOT}/tests"
}

# Spikes are throwaway validation programs, not product code. docs/11: the
# spike code may be discarded; its measurements and decisions remain.
cmd_spike() {
	require_odin
	local name="${1:-}"
	if [[ -z "${name}" ]]; then
		echo "error: spike requires a name (graphics)" >&2
		exit 2
	fi
	shift
	local dir="${ROOT}/spike/${name}"
	if [[ ! -d "${dir}" ]]; then
		echo "error: no spike named '${name}'" >&2
		exit 2
	fi
	mkdir -p "${ARTIFACTS_DIR}"
	odin build "${dir}" "${COLLECTION[@]}" -o:speed -out:"${ARTIFACTS_DIR}/spike_${name}"
	"${ARTIFACTS_DIR}/spike_${name}" "$@"
}

cmd_clean() {
	rm -rf "${BUILD_DIR}" "${ARTIFACTS_DIR}"
	echo "removed build and artifact directories"
}

main() {
	local command="${1:-}"
	[[ $# -gt 0 ]] && shift || true
	case "${command}" in
		build)        cmd_build "$@" ;;
		run)          cmd_run "$@" ;;
		test)         cmd_test "$@" ;;
		check)        cmd_check "$@" ;;
		format-check) cmd_format_check "$@" ;;
		spike)        cmd_spike "$@" ;;
		clean)        cmd_clean "$@" ;;
		-h|--help|help|"") usage ;;
		*)
			echo "error: unknown command '${command}'" >&2
			usage >&2
			exit 2
			;;
	esac
}

main "$@"
