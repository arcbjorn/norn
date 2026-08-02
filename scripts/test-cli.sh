#!/usr/bin/env bash
# CLI contract tests.
#
# docs/10 fixes the command surface and the exit codes, and scripts branch on
# those codes. The Odin test packages cover library behaviour; these cover what
# only the built binary can show — argument parsing, which stream output goes
# to, and the exit code each failure produces.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NORN="${ROOT}/build/norn"

failed=0
checks=0
scratch=""

# expect_code <expected> <description> -- <command...>
expect_code() {
	local expected="$1"
	local description="$2"
	shift 3 # expected, description, "--"

	checks=$((checks + 1))
	"$@" >/dev/null 2>&1
	local actual=$?
	if [[ "${actual}" != "${expected}" ]]; then
		echo "FAIL: ${description}: expected exit ${expected}, got ${actual}"
		failed=1
	fi
}

# expect_stderr <pattern> <description> -- <command...>
#
# Diagnostics belong on stderr so stdout stays reserved for machine-readable
# output. A message on the wrong stream breaks `norn inspect --json | jq`.
expect_stderr() {
	local pattern="$1"
	local description="$2"
	shift 3

	checks=$((checks + 1))
	local output
	output="$("$@" 2>&1 1>/dev/null)"
	if [[ "${output}" != *"${pattern}"* ]]; then
		echo "FAIL: ${description}: stderr lacked \"${pattern}\""
		echo "      got: ${output}"
		failed=1
	fi
}

# expect_stdout_empty <description> -- <command...>
expect_stdout_empty() {
	local description="$1"
	shift 2

	checks=$((checks + 1))
	local output
	output="$("$@" 2>/dev/null)"
	if [[ -n "${output}" ]]; then
		echo "FAIL: ${description}: stdout was not empty"
		echo "      got: ${output}"
		failed=1
	fi
}

main() {
	if [[ ! -x "${NORN}" ]]; then
		echo "error: ${NORN} is not built; run scripts/norn.sh build" >&2
		return 1
	fi

	scratch="$(mktemp -d)"
	trap 'rm -rf "${scratch}"' EXIT

	local source="${scratch}/session.jsonl"
	echo '{"type":"message"}' >"${source}"

	# Usage errors.
	expect_code 2 "import without a source" -- "${NORN}" import
	expect_code 2 "import without --repo" -- "${NORN}" import "${source}"
	expect_code 2 "import with an unknown option" -- \
		"${NORN}" import "${source}" --repo "${ROOT}" --bogus
	expect_code 2 "import with two sources" -- \
		"${NORN}" import "${source}" "${source}" --repo "${ROOT}"
	expect_code 2 "--repo without a value" -- "${NORN}" import "${source}" --repo
	expect_code 2 "--out without a value" -- "${NORN}" import "${source}" --out
	expect_code 2 "--format without a value" -- "${NORN}" import "${source}" --format
	expect_code 2 "an unknown command" -- "${NORN}" frobnicate

	# Input errors are distinct from usage errors: a script retries one and not
	# the other.
	expect_code 3 "a source that does not exist" -- \
		"${NORN}" import "${scratch}/absent.jsonl" --repo "${ROOT}"

	# docs/05: a build with no adapters cannot import, and says so rather than
	# reporting an unrecognized format.
	expect_code 5 "import with no adapters registered" -- \
		"${NORN}" import "${source}" --repo "${ROOT}"
	expect_stderr "no importers" "the missing-adapter message names the cause" -- \
		"${NORN}" import "${source}" --repo "${ROOT}"

	# Every failure keeps stdout clean.
	expect_stdout_empty "a usage error writes nothing to stdout" -- "${NORN}" import
	expect_stdout_empty "an input error writes nothing to stdout" -- \
		"${NORN}" import "${scratch}/absent.jsonl" --repo "${ROOT}"
	expect_stdout_empty "an unknown command writes nothing to stdout" -- \
		"${NORN}" frobnicate

	# No destination may be left behind by a failed import.
	checks=$((checks + 1))
	"${NORN}" import "${source}" --repo "${ROOT}" --out "${scratch}/out.norn" >/dev/null 2>&1
	if [[ -e "${scratch}/out.norn" ]]; then
		echo "FAIL: a failed import left a destination behind"
		failed=1
	fi

	# The default destination is derived beside the source, so a loop over
	# several logs does not collide on one output name.
	checks=$((checks + 1))
	if [[ -e "${scratch}/session.norn" ]]; then
		echo "FAIL: a failed import wrote the default destination"
		failed=1
	fi

	# Successful commands.
	expect_code 0 "version" -- "${NORN}" version
	expect_code 0 "help" -- "${NORN}" help

	# Usage lists import as available, not as unimplemented.
	checks=$((checks + 1))
	if ! "${NORN}" help | grep -q "norn import"; then
		echo "FAIL: usage does not list the import command"
		failed=1
	fi
	checks=$((checks + 1))
	if "${NORN}" help | grep -q "not yet implemented"; then
		echo "FAIL: usage still lists import as unimplemented"
		failed=1
	fi

	# A usage error prints usage to stderr; a help request prints it to stdout.
	expect_stderr "Usage:" "a usage error prints usage to stderr" -- "${NORN}" frobnicate

	if [[ "${failed}" == 0 ]]; then
		echo "Finished ${checks} CLI checks. All checks passed."
	else
		echo "Some CLI checks failed."
	fi
	return "${failed}"
}

main "$@"
