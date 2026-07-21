# Development

## Prerequisites

The project requires:

- a pinned Odin compiler release;
- Clang and platform development tools;
- SDL3 development libraries;
- the selected WGPU native library or build artifact;
- Git for importer baseline reads and developer workflows.

Exact versions and bootstrap commands belong in the root README and build
scripts once the phase-zero stack spike is complete. Do not document guessed
commands before they work in CI.

## Intended repository layout

```text
docs/                   product and engineering specification
src/                    Odin source packages
tests/                  test packages and sanitized fixtures
assets/                 fonts, icons, themes, and shader source
scripts/                repeatable developer and release commands
third_party/            pinned source or metadata when vendoring is required
build.odin               project build orchestration, if adopted
README.md                concise setup and product overview
LICENSE
SECURITY.md
```

Generated files go under `build/` and are ignored. Test output goes under a
dedicated ignored artifacts directory so failures do not dirty source folders.

## Build profiles

The supported profiles are:

- `debug`: checks enabled, symbols, validation diagnostics, developer overlay;
- `release`: optimized, assertions that protect file safety retained;
- `sanitize`: native dependencies and compatible code built with sanitizers
  where the platform permits;
- `profile`: optimized with tracing and benchmark instrumentation.

Security checks for bounds, container integrity, path safety, and resource
limits remain enabled in every profile.

## Command surface

The eventual developer interface should provide stable commands equivalent to:

```text
build
run [trace]
test [package]
test-golden
test-corruption
benchmark [suite]
format-check
validate-fixtures
package
```

Whether these are implemented with an Odin build program, shell scripts, or a
small task runner is decided during phase zero. CI and developers must call the
same underlying commands.

The product CLI is separate:

```text
norn                         open the desktop application
norn open <trace.norn>
norn import <source> --repo <path> [--format codex] [--out file.norn]
norn inspect <trace.norn> [--json]
norn validate <trace.norn> [--mode quick|full|replay]
norn export <trace.norn> --range <start:end> --out <directory>
```

CLI commands use explicit exit codes and keep machine-readable output on stdout
separate from diagnostics on stderr.

## Odin conventions

- Package names are short and describe a capability.
- Public declarations have documentation comments.
- Procedures receive allocators when ownership is not bound to an object.
- Ownership and lifetime are stated for returned slices and pointers.
- Use `defer` near successful acquisition of resources.
- Avoid implicit reliance on map iteration order.
- Use distinct types for identifiers, offsets, timestamps, and byte sizes.
- Prefer structure-of-arrays for hot event data and array-of-structures for
  small control records where clarity matters more.
- Validate conversions between signed and unsigned values.
- Keep platform and foreign-library types at adapter boundaries.

## Error conventions

Do not discard errors from file, codec, GPU, or process operations. Add context
once at the boundary that knows the operation and subject. Avoid repeatedly
wrapping the same message at every stack layer.

User-facing errors are stable categories plus detail. Internal diagnostics may
include source locations and backend codes but never secret content.

## Logging

Logs are structured and local. Levels:

- error: operation failed and user-visible behavior is affected;
- warning: degraded result or recovered inconsistency;
- info: lifecycle milestones such as import completion;
- debug: detailed codec, replay, and renderer diagnostics;
- trace: high-volume development-only events.

Trace content and file content are not logged by default. Event identifiers,
hash prefixes, sizes, and categories are sufficient for most diagnostics.

## Adding an importer

1. Add sanitized fixtures and provenance.
2. Implement detection with explicit confidence reasons.
3. Map records only to documented canonical semantics.
4. Preserve unknown records or report their disposition.
5. Add redaction coverage.
6. Add a golden canonical summary.
7. Add replay fixtures for every supported mutation representation.
8. Document source variants and capability differences.

An importer is not considered supported because it parses one personal trace.

## Changing the trace model or format

Before changing canonical semantics:

1. State the user-visible problem.
2. Update the trace-model document.
3. Decide whether the change is compatible.
4. Add old and new fixtures.
5. Update codec, validator, importer, analysis, and export tests.
6. Record the decision when it changes a settled tradeoff.

Derived analysis changes do not require a format change when canonical evidence
is sufficient to rebuild them.

## Git workflow

- Keep commits granular and conventional.
- Do not commit private or unsanitized traces.
- Do not mix generated fixture updates with unrelated behavior.
- Run format and relevant tests before committing.
- Review binary fixture changes through their generated semantic summaries.
