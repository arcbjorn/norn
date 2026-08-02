# Hostile fixtures

docs/11 Phase 5 requires that "opening all hostile fixtures causes no execution,
repository writes, crashes, or unbounded allocation." These are those fixtures.

Each one attacks a specific property from the non-negotiable list in docs/08.
They are checked in as NSL source logs rather than `.norn` containers because
the import path is where untrusted provider content enters the system;
container-level corruption is covered separately by `tests/codec`.

## Provenance

Every fixture in this directory is synthetic, written by hand for this test
suite. Per docs/05 they contain no real credentials, prompts, usernames, home
paths, or source from other projects. The credential-shaped strings are
invented and match no issued key.

`scripts/test-security.sh` runs them.

## What each fixture attacks

| Fixture | docs/08 property |
| --- | --- |
| `command-injection.jsonl` | never execute a command, script, or binary |
| `path-escape.jsonl` | never resolve a path outside the repository boundary |
| `network.jsonl` | never fetch a URL or contact a provider |
| `markup-injection.jsonl` | never render arbitrary HTML or active content |
| `format-string.jsonl` | provider records never become format strings |
| `secrets.jsonl` | never expose unredacted secrets in an export by default |
| `repository-write.jsonl` | never checkout or mutate a repository |
| `resource-exhaustion.jsonl` | bounded allocation; no unbounded growth |
| `encoding.jsonl` | bounded UTF-8 validation, invalid encodings rejected |
| `structure.jsonl` | malformed records fail without partial initialization |

## Why these are source logs, not containers

A hostile `.norn` file tests the validator. A hostile *source log* tests
everything downstream of it: the adapter, the sink, redaction, the writer, and
then the reader, replay, and export over content an attacker chose. The second
is the larger surface, and it is the one a user is actually exposed to when they
import a trace someone sent them.
