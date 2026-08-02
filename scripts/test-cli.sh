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

	# docs/05: a file is not a given format merely because it is JSONL, so a log
	# with no NSL header is refused rather than imported by guess.
	expect_code 5 "a source no adapter recognizes" -- \
		"${NORN}" import "${source}" --repo "${ROOT}"
	expect_stderr "no importer recognizes" "an unrecognized source names the cause" -- \
		"${NORN}" import "${source}" --repo "${ROOT}"
	# One unsure adapter is not an ambiguity, and must not be reported as one.
	checks=$((checks + 1))
	weak_output="$("${NORN}" import "${source}" --repo "${ROOT}" 2>&1)"
	if [[ "${weak_output}" == *"is ambiguous"* ]]; then
		echo "FAIL: a single weak claim was reported as ambiguous"
		failed=1
	fi

	# An unknown --format lists what is available rather than failing blankly.
	expect_code 2 "an unknown format" -- \
		"${NORN}" import "${source}" --repo "${ROOT}" --format nope
	expect_stderr "available formats" "an unknown format lists the real ones" -- \
		"${NORN}" import "${source}" --repo "${ROOT}" --format nope

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

	# A real import, end to end. docs/11: the trace must be inspectable without
	# the source it came from.
	local nsl="${scratch}/session.nsl.jsonl"
	{
		echo '{"type":"session","nsl_version":1,"started_at":1000}'
		echo '{"type":"message","t":1100,"role":"user","text":"fix the test"}'
		echo '{"type":"file","t":1200,"op":"modify","path":"a.odin","before":"x\n","after":"y\n"}'
		echo '{"type":"command","t":1300,"command":"odin test","exit":0,"output":"ok"}'
	} >"${nsl}"

	expect_code 0 "importing an NSL log" -- \
		"${NORN}" import "${nsl}" --repo "${ROOT}" --out "${scratch}/good.norn"

	checks=$((checks + 1))
	if [[ ! -e "${scratch}/good.norn" ]]; then
		echo "FAIL: a successful import wrote no destination"
		failed=1
	fi

	# The source is removed before reading the trace back, so nothing can be
	# quietly resolved from it.
	rm -f "${nsl}"
	expect_code 0 "validating the imported trace" -- \
		"${NORN}" validate "${scratch}/good.norn" --mode full
	expect_code 0 "replaying the imported trace" -- \
		"${NORN}" validate "${scratch}/good.norn" --mode replay
	expect_code 0 "inspecting the imported trace" -- \
		"${NORN}" inspect "${scratch}/good.norn"

	# The mutation must reconstruct, not merely be present.
	checks=$((checks + 1))
	replay_output="$("${NORN}" validate "${scratch}/good.norn" --mode replay 2>/dev/null)"
	if [[ "${replay_output}" != *"verified:   1"* ]]; then
		echo "FAIL: the imported mutation did not replay"
		failed=1
	fi

	# --dry-run reports what a source contains without writing output.
	local dry="${scratch}/dry.jsonl"
	{
		echo '{"type":"session","nsl_version":1}'
		echo '{"type":"message","t":1,"role":"user","text":"hello"}'
		echo '{"type":"checkpoint","t":2}'
	} >"${dry}"

	expect_code 0 "a dry run" -- "${NORN}" import "${dry}" --dry-run
	checks=$((checks + 1))
	if [[ -e "${scratch}/dry.norn" ]]; then
		echo "FAIL: a dry run wrote a destination"
		failed=1
	fi
	# docs/01: unsupported record types are reported before output is written.
	checks=$((checks + 1))
	dry_output="$("${NORN}" import "${dry}" --dry-run 2>/dev/null)"
	if [[ "${dry_output}" != *"checkpoint"* ]]; then
		echo "FAIL: a dry run did not name the unsupported record type"
		failed=1
	fi

	# Successful commands.
	expect_code 0 "version" -- "${NORN}" version
	expect_code 0 "help" -- "${NORN}" help

	# Usage lists import as available, not as unimplemented.
	checks=$((checks + 1))
	help_output="$("${NORN}" help)"
	if [[ "${help_output}" != *"norn import"* ]]; then
		echo "FAIL: usage does not list the import command"
		failed=1
	fi
	checks=$((checks + 1))
	if [[ "${help_output}" == *"not yet implemented"* ]]; then
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
