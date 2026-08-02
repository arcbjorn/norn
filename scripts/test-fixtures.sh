#!/usr/bin/env bash
# Fixture determinism gate.
#
# docs/09 requires generated fixtures to be reproducible, and the hashes in
# tests/fixtures/README.md are the record of that. This checks them.
#
# The property matters because every performance figure in
# docs/13-engineering-notes.md was measured against these files. If the
# generator drifts, a slower run stops meaning the code got slower — and that
# is a hard failure to notice, because nothing looks broken.
#
# Only the two small tiers run here. Reference and stress take minutes and
# produce over a gigabyte; verify those by hand before a release.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="${ROOT}/tests/fixtures/README.md"

failed=0
checks=0
scratch=""

main() {
	scratch="$(mktemp -d)"
	trap 'rm -rf "${scratch}"' EXIT

	local tier
	for tier in tiny representative; do
		# The expected hash comes from the provenance table rather than a
		# constant here, so the documentation cannot drift from the check.
		# Scoped to the two-column hash table: the tier-size table above it also
		# keys on the tier name, and matching both concatenates their cells.
		local expected
		expected="$(awk -F'|' -v t=" ${tier} " '
			NF == 4 && $2 == t && $3 ~ /`[0-9a-f]{64}`/ {
				gsub(/[ `]/, "", $3)
				print $3
			}' "${README}")"

		checks=$((checks + 1))
		if [[ -z "${expected}" ]]; then
			echo "FAIL: no expected hash recorded for the ${tier} tier"
			failed=1
			continue
		fi

		if ! "${ROOT}/scripts/norn.sh" fixture "${tier}" "${scratch}/${tier}.jsonl" \
			>/dev/null 2>&1; then
			echo "FAIL: could not generate the ${tier} tier"
			failed=1
			continue
		fi

		local actual
		actual="$(shasum -a256 "${scratch}/${tier}.jsonl" | cut -d' ' -f1)"

		checks=$((checks + 1))
		if [[ "${actual}" != "${expected}" ]]; then
			echo "FAIL: the ${tier} tier is not reproducible"
			echo "      expected ${expected}"
			echo "      got      ${actual}"
			echo "      If the generator changed deliberately, update the table in"
			echo "      tests/fixtures/README.md and bump VERSION in the generator."
			failed=1
		fi
	done

	# Generating twice must also agree, which catches a generator that reads a
	# clock or iterates a map — a source of nondeterminism the stored hash
	# would only catch on a machine where it happened to differ.
	checks=$((checks + 1))
	"${ROOT}/scripts/norn.sh" fixture tiny "${scratch}/again.jsonl" >/dev/null 2>&1
	if ! cmp -s "${scratch}/tiny.jsonl" "${scratch}/again.jsonl"; then
		echo "FAIL: two runs of the generator disagree"
		failed=1
	fi

	if [[ "${failed}" == 0 ]]; then
		echo "Finished ${checks} fixture checks. All checks passed."
	else
		echo "Some fixture checks failed."
	fi
	return "${failed}"
}

main "$@"
