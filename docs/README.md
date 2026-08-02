# Norn documentation

Norn is a native time-travel debugger for coding-agent sessions. It imports an
agent trace, reconstructs how the repository changed, and presents prompts,
tool calls, edits, commands, tests, and errors on one navigable timeline.

The defining interaction is simple: select an outcome, such as a test that
started failing, and move backward through the evidence that preceded it.

## Document map

Read these documents in order when first joining the project.

| Document | Purpose |
| --- | --- |
| [Product](00-product.md) | Vision, audience, scope, and success criteria |
| [User experience](01-user-experience.md) | Workflows, screen layout, and interaction rules |
| [Architecture](02-architecture.md) | Process model, packages, data flow, and boundaries |
| [Trace model](03-trace-model.md) | Canonical events, entities, edges, and invariants |
| [Trace format](04-trace-format.md) | The `.norn` binary container and compatibility rules |
| [Importers](05-importers.md) | Adapter contract and Codex importer behavior |
| [Replay and analysis](06-replay-and-analysis.md) | Repository reconstruction and causal inference |
| [Rendering](07-rendering.md) | Native UI, GPU pipeline, and performance budgets |
| [Security](08-security.md) | Trust boundaries, redaction, and safe handling |
| [Quality](09-quality.md) | Test strategy, fixtures, benchmarks, and release gates |
| [Development](10-development.md) | Repository layout, commands, style, and workflow |
| [Roadmap](11-roadmap.md) | Milestones and definition of done |
| [Decisions](12-decisions.md) | Accepted architectural decisions and open questions |
| [Spike results](13-spike-results.md) | Phase-zero measurements and dependency findings |

## Source of truth

These documents describe the intended first release. When implementation and
documentation disagree, resolve the disagreement explicitly: either fix the
implementation or record a decision and update the affected documents. Do not
allow behavior to become an accidental specification.

The most normative documents are:

1. `03-trace-model.md` for semantic meaning.
2. `04-trace-format.md` for bytes on disk.
3. `08-security.md` for non-negotiable safety properties.
4. `12-decisions.md` for settled tradeoffs.
