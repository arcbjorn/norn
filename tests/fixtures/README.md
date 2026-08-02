# Fixtures

docs/09 defines four fixture tiers and requires that "large fixtures are
generated deterministically when possible" and that "any checked-in binary
fixture needs provenance, license, generator version, and expected hash."

No binary fixture is checked in. Everything here is either a small text file
written by hand or generated on demand from a seeded generator, which is what
lets a 1.4 GB stress tier exist without living in the repository.

## Generated tiers

Produced by `scripts/norn.sh fixture <tier>`, which builds
[`src/tools/genfixture`](../../src/tools/genfixture) and runs it.

| Tier | Records | Events | Size | Use |
| --- | ---: | ---: | ---: | --- |
| tiny | 40 | 42 | 65 KB | unit and error-path tests |
| representative | 2,000 | 2,317 | 4.5 MB | golden and end-to-end tests |
| reference | 60,000 | 69,400 | 140 MB | release performance gate |
| stress | 600,000 | 693,635 | 1.4 GB | manual scalability testing |

Determinism is the point. The generator uses its own seeded xorshift rather
than `core:math/rand`, so a fixture stays identical across compiler and
standard-library versions; it reads no clock, no environment, and no directory
listing. A tier name alone reproduces the file byte for byte.

That is what makes a performance regression meaningful: if the input can drift,
a slower run tells you nothing about the code.

### Expected hashes

Generator version 1, verified after a clean rebuild:

| Tier | SHA-256 |
| --- | --- |
| tiny | `6d9735698e120ac13d5e858639ef511dd5b7d45ee605cfa4783a71e1f839fd03` |
| representative | `1cdcf305e56c06daa0f956ff6ed73b966817d867e716d1a6e96b71ba07e21bc3` |
| reference | `55d8cc4c7b50fb098c002c3e3e71f0e5cbfcb5d655d1406a3cb73db1a05447ac` |
| stress | `90419d8921e2482ed8827605b9422a7d28188fa1bfbcb7c2dac70fe857cd465f` |

`scripts/test-fixtures.sh` checks the first two on every run. The reference and
stress tiers are excluded because generating them takes minutes and produces
gigabytes; verify them manually before a release.

A deliberate change to the generator changes these hashes. Update the table in
the same commit, and bump `VERSION` in the generator so an old hash is
attributable to an old generator rather than to a bug.

## Hostile fixtures

[`hostile/`](hostile) holds adversarial source logs for the security gate. Its
own README documents what each one attacks.

## Provenance and licensing

Every fixture in this tree is synthetic, written for this repository, and
covered by the project's MIT license. Per docs/05 none contains real
credentials, prompts, usernames, home paths, or source from other projects —
the credential-shaped strings are invented and match no issued key.

This matters beyond licensing. A fixture derived from a real session would put
someone's prompts and file content into a public repository permanently, which
is the exact exposure Norn's redaction exists to prevent.

A future provider adapter will need fixtures derived from real traces. Those
must be sanitized before entering the repository, and their provenance recorded
here.
