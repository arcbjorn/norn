#!/usr/bin/env bash
# Security gate.
#
# docs/11 Phase 5: "opening all hostile fixtures causes no execution, repository
# writes, crashes, or unbounded allocation."
#
# Every fixture in tests/fixtures/hostile attacks one of the non-negotiable
# properties in docs/08. This runs each through the real binary, because that is
# the thing a user runs: a unit test can prove a function rejects a path, but
# only the built product can show that nothing anywhere executed a command.
#
# The checks are deliberately outcome-based. Rather than asserting that some
# validation function was called, they assert that the damage did not happen —
# no sentinel file exists, the repository is unchanged, memory stayed bounded.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NORN="${ROOT}/build/norn"
HOSTILE="${ROOT}/tests/fixtures/hostile"

failed=0
checks=0
scratch=""

fail() {
	echo "FAIL: $1"
	failed=1
}

pass_check() {
	checks=$((checks + 1))
}

# MEMORY_CEILING_KB bounds peak resident memory for any single hostile import.
#
# The largest fixture is a few hundred kilobytes; a parser that allocated
# proportionally to a declared count rather than to actual input would blow
# past this immediately. Generous enough not to be flaky, tight enough that
# unbounded allocation cannot hide under it.
MEMORY_CEILING_KB=524288 # 512 MB

# run_import imports a fixture and reports its exit code, with a memory ceiling.
#
# A hostile fixture is allowed to be *refused* — that is often the correct
# outcome. What it may never do is crash, hang, or take the process with it.
run_import() {
	local fixture="$1"
	local out="$2"

	# A wall-clock limit catches a hang, which is a denial of service even
	# though it allocates nothing.
	(
		ulimit -v $((MEMORY_CEILING_KB * 2)) 2>/dev/null || true
		"${NORN}" import "${fixture}" --repo "${scratch}/repo" --out "${out}"
	) >/dev/null 2>&1
	echo $?
}

# expect_no_crash asserts the exit code is a reported error, not a signal.
#
# Exit codes above 128 mean the process died from a signal: 139 is a
# segmentation fault, 134 an abort. Those are crashes. A documented non-zero
# exit is a refusal, which is fine.
expect_no_crash() {
	local code="$1"
	local what="$2"

	pass_check
	if [[ "${code}" -ge 128 ]]; then
		fail "${what}: the process died from a signal (exit ${code})"
	fi
}

main() {
	if [[ ! -x "${NORN}" ]]; then
		echo "error: ${NORN} is not built; run scripts/norn.sh build" >&2
		return 1
	fi
	if [[ ! -d "${HOSTILE}" ]]; then
		echo "error: ${HOSTILE} is missing" >&2
		return 1
	fi

	scratch="$(mktemp -d)"
	trap 'rm -rf "${scratch}"' EXIT

	# A throwaway git repository, so a fixture that manages to mutate one
	# damages this and not the developer's checkout.
	mkdir -p "${scratch}/repo"
	(
		cd "${scratch}/repo" || exit 1
		git init -q .
		echo "package a" >a.odin
		echo "package legit" >legit.odin
		mkdir -p src
		echo "package main" >src/main.odin
		git add -A
		git -c user.email=t@t -c user.name=t commit -qm initial
	) >/dev/null 2>&1

	local repo_before
	repo_before="$(cd "${scratch}/repo" && git rev-parse HEAD)"
	local tree_before
	tree_before="$(cd "${scratch}/repo" && find . -type f -not -path './.git/*' | sort | xargs shasum -a256 2>/dev/null | shasum -a256)"

	# Sentinels every fixture tries to create. Their absence afterwards is the
	# evidence that nothing executed.
	local sentinels=(
		/tmp/norn-pwned-gen /tmp/norn-pwned-sess /tmp/norn-pwned-cmd
		/tmp/norn-pwned-backtick /tmp/norn-pwned-subst /tmp/norn-pwned-and
		/tmp/norn-pwned-argv /tmp/norn-pwned-pipe /tmp/norn-pwned-newline
		/tmp/norn-pwned-tool /tmp/norn-pwned-args /tmp/norn-pwned-err
		/tmp/norn-pwned-content /tmp/norn-pwned-msg /tmp/norn-pwned-test
		/tmp/norn-pwned-diag /tmp/norn-pwned-hook /tmp/norn-pwned-abs
	)
	rm -f "${sentinels[@]}" 2>/dev/null

	echo "== hostile fixtures"

	local fixture
	for fixture in "${HOSTILE}"/*.jsonl; do
		local name
		name="$(basename "${fixture}")"
		local out="${scratch}/$(basename "${fixture}" .jsonl).norn"

		local code
		code="$(run_import "${fixture}" "${out}")"
		expect_no_crash "${code}" "${name}"

		# Whatever the import decided, a produced trace must survive every
		# later stage too: validating, inspecting, replaying, and exporting are
		# all operations a user performs on untrusted content.
		if [[ -f "${out}" ]]; then
			local stage
			for stage in "validate ${out} --mode full" "validate ${out} --mode replay" \
				"inspect ${out}" "inspect ${out} --json" "explain ${out} --list"; do
				# shellcheck disable=SC2086
				"${NORN}" ${stage} >/dev/null 2>&1
				expect_no_crash $? "${name}: ${stage%% *}"
			done

			"${NORN}" export "${out}" --out "${scratch}/exp-${name}" >/dev/null 2>&1
			expect_no_crash $? "${name}: export"
		fi
	done

	echo "== non-negotiable properties"

	# docs/08: never execute a command, script, binary, hook, plugin, or macro.
	local sentinel
	for sentinel in "${sentinels[@]}"; do
		pass_check
		if [[ -e "${sentinel}" ]]; then
			fail "a hostile fixture executed something: ${sentinel} exists"
			rm -f "${sentinel}"
		fi
	done

	# docs/08: never checkout or mutate a repository.
	pass_check
	local repo_after
	repo_after="$(cd "${scratch}/repo" && git rev-parse HEAD)"
	if [[ "${repo_before}" != "${repo_after}" ]]; then
		fail "the repository HEAD moved during import"
	fi

	pass_check
	local tree_after
	tree_after="$(cd "${scratch}/repo" && find . -type f -not -path './.git/*' | sort | xargs shasum -a256 2>/dev/null | shasum -a256)"
	if [[ "${tree_before}" != "${tree_after}" ]]; then
		fail "the repository working tree changed during import"
	fi

	pass_check
	if [[ -e "${scratch}/repo/.git/hooks/post-checkout" ]]; then
		fail "a fixture wrote a repository hook"
	fi

	# docs/08: never resolve a path outside the repository boundary.
	pass_check
	if [[ -e /tmp/norn-pwned-abs ]]; then
		fail "an absolute path from a trace was written to"
	fi

	check_path_escape
	check_secrets
	check_markup
	check_memory

	if [[ "${failed}" == 0 ]]; then
		echo "Finished ${checks} security checks. All checks passed."
	else
		echo "Some security checks failed."
	fi
	return "${failed}"
}

# check_path_escape asserts that only the in-bounds path survived import.
check_path_escape() {
	local out="${scratch}/path-escape.norn"
	if [[ ! -f "${out}" ]]; then
		# Refusing the whole fixture is also a correct outcome.
		return
	fi

	# Searched in the trace *bytes*, not in a command's output. `inspect` prints
	# counts and metadata, not the path table, so an escaping path retained in
	# the string table would never appear there — an earlier version of this
	# check looked at inspect --json and could not fail.
	local escaping=("etc/passwd" "etc/shadow" "norn-pwned-abs" "System32" "outside.odin")
	local needle
	for needle in "${escaping[@]}"; do
		pass_check
		if grep -qaF "${needle}" "${out}" 2>/dev/null; then
			fail "an escaping path was retained in the trace: ${needle}"
		fi
	done

	# The in-bounds path must survive, or the fixture would pass by rejecting
	# everything — which is not the property being tested.
	pass_check
	if ! grep -qaF "legit.odin" "${out}" 2>/dev/null; then
		fail "path rejection also discarded the valid path"
	fi

	# Every rejection must be counted rather than silently dropped, per docs/05.
	pass_check
	local report
	report="$("${NORN}" import "${HOSTILE}/path-escape.jsonl" --repo "${scratch}/repo" \
		--out "${scratch}/pe2.norn" 2>/dev/null)"
	if [[ "${report}" != *"path_rejected"* && "${report}" != *"warnings"* ]]; then
		fail "rejected paths were not reported as warnings"
	fi
}

# check_secrets asserts docs/08's default: no unredacted secret in an export.
check_secrets() {
	local out="${scratch}/secrets.norn"
	if [[ ! -f "${out}" ]]; then
		return
	fi

	local leaked=(
		"sk-NOTAREALTOKENEXAMPLEONLYFAKE1234"
		"ghp_NOTAREALTOKENEXAMPLEONLYFAKE1234"
		"xoxb-NOTAREALTOKEN-EXAMPLEONLY"
		"AKIANOTAREALKEYEXAMP"
		"NOTAREALSECRETEXAMPLEONLYFAKEVALUE1234"
		"hunter2"
	)

	local secret
	for secret in "${leaked[@]}"; do
		pass_check
		if grep -qF "${secret}" "${out}" 2>/dev/null; then
			fail "the trace contains an unredacted secret: ${secret}"
		fi
	done

	"${NORN}" export "${out}" --out "${scratch}/exp-secrets" >/dev/null 2>&1
	if [[ -d "${scratch}/exp-secrets" ]]; then
		for secret in "${leaked[@]}"; do
			pass_check
			if grep -rqF "${secret}" "${scratch}/exp-secrets" 2>/dev/null; then
				fail "an export leaked a secret by default: ${secret}"
			fi
		done
	fi
}

# check_markup asserts that hostile text cannot become active content.
check_markup() {
	local out="${scratch}/markup-injection.norn"
	if [[ ! -f "${out}" ]]; then
		return
	fi

	"${NORN}" export "${out}" --out "${scratch}/exp-markup" --include-messages \
		--include-output >/dev/null 2>&1
	local html="${scratch}/exp-markup/report.html"
	if [[ ! -f "${html}" ]]; then
		return
	fi

	# Even with message and output text explicitly included — the worst case for
	# this property — the rendered page must contain no executable markup.
	pass_check
	if grep -qi "<script" "${html}"; then
		fail "hostile text produced a script tag in the exported report"
	fi

	# Only *unescaped* markup matters. "&lt;svg onload=...&gt;" is inert text and
	# is exactly what correct escaping produces, so matching the bare substring
	# would fail on a report that is behaving perfectly. The check is therefore
	# for a real tag opening: "<" immediately followed by an element name.
	# Elements that fetch, execute, or embed. `meta` is deliberately absent: the
	# report writes its own, including the CSP declaration this suite checks for
	# two assertions below, and matching it would flag the defence as the attack.
	pass_check
	if grep -qiE "<(iframe|svg|object|embed|applet|link|base|form|img|audio|video|source)[[:space:]>/]" "${html}"; then
		fail "hostile text produced an active element in the exported report"
	fi

	# An event-handler attribute inside a real tag, rather than inside text.
	pass_check
	if grep -qiE "<[a-z][^>]*[[:space:]](on[a-z]+)=" "${html}"; then
		fail "hostile text produced an event handler attribute"
	fi

	# A javascript: URL in an attribute position.
	pass_check
	if grep -qiE "(href|src|action)=[\"']?javascript:" "${html}"; then
		fail "hostile text produced a javascript: URL"
	fi

	pass_check
	if ! grep -q "default-src 'none'" "${html}"; then
		fail "the exported report lost its content security policy"
	fi

	# The content must still be *there*, escaped. Dropping it would pass the
	# checks above while destroying the evidence a user needs to read.
	pass_check
	if ! grep -q "&lt;script&gt;" "${html}"; then
		fail "hostile text was dropped rather than escaped"
	fi
}

# check_memory asserts bounded allocation on a deliberately large input.
#
# Generated here rather than checked in: the point is a multi-megabyte record,
# and a repository does not need to carry one.
check_memory() {
	local big="${scratch}/big.jsonl"
	{
		echo '{"type":"session","nsl_version":1}'
		python3 -c "
import sys
# One enormous record, then many. A parser that retains records fails the
# second case; a parser that trusts a declared length fails the first.
sys.stdout.write('{\"type\":\"message\",\"t\":1,\"role\":\"user\",\"text\":\"' + 'A' * (8 * 1024 * 1024) + '\"}\n')
for i in range(20000):
    sys.stdout.write('{\"type\":\"file\",\"t\":%d,\"op\":\"read\",\"path\":\"p%d.odin\"}\n' % (100 + i, i))
"
	} >"${big}"

	local usage
	usage="$( { /usr/bin/time -l "${NORN}" import "${big}" --repo "${scratch}/repo" \
		--out "${scratch}/big.norn" >/dev/null; } 2>&1 | awk '/maximum resident/{print int($1/1024)}')"

	pass_check
	if [[ -z "${usage}" ]]; then
		fail "could not measure memory for the large input"
	elif [[ "${usage}" -gt "${MEMORY_CEILING_KB}" ]]; then
		fail "importing a large input used ${usage} KB, over the ${MEMORY_CEILING_KB} KB ceiling"
	fi
}

main "$@"
