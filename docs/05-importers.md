# Importers

## Responsibility

An importer converts one unstable provider format into Norn's stable canonical
model. It owns source detection, parsing, normalization, redaction, provenance,
and warnings. It does not own replay, UI presentation, or causal analysis.

## Adapter interface

Conceptually, an adapter provides:

```text
Importer {
    id() -> string
    version() -> semantic version
    detect(prefix, path_hint) -> Detection
    inspect(source) -> Source_Metadata
    import(source, repository, sink, options) -> Import_Report
}
```

`Detection` contains confidence and reasons. Auto-detection proceeds only when
one adapter has high confidence and no adapter has comparable confidence.
Otherwise the user chooses explicitly.

The sink accepts canonical records in sequence order and provides string and
blob interning. Importers cannot write container bytes directly.

## Capabilities

Each imported session declares observed capabilities:

- wall-clock timestamps;
- monotonic timing;
- stable event identifiers;
- nested spans;
- visible conversation text;
- structured tool calls;
- file reads;
- patches;
- before or after file content;
- command boundaries and output;
- structured test results;
- token usage;
- sub-agent identity;
- raw record preservation.

The UI derives feature availability from this manifest. Missing data is not an
error and must not be presented as recorded evidence.

## Import pipeline

```text
detect -> inspect -> stream parse -> redact -> normalize -> correlate
       -> validate batches -> write canonical chunks -> build indexes
       -> full validation -> atomic publish
```

The parser is streaming. It must not load the entire source log into memory.
Records are processed in bounded batches and committed to the temporary trace
writer only after batch validation.

## Codex importer

The first adapter targets a versioned Codex JSONL trace family. Support is based
on fixtures, not on assumptions that every JSON object with similar fields is
compatible.

The adapter must:

1. Identify source schema variants from record shape and known metadata.
2. Preserve source order as canonical sequence order.
3. Map visible user, assistant, and system messages.
4. Pair tool calls with results using explicit identifiers when available.
5. Recover spans for command and tool lifecycles.
6. Normalize file observations and mutations.
7. Separate command output from application diagnostics.
8. Record token usage and provider transitions when present.
9. Retain unknown record types as extension events or report why they were
   ignored.
10. Emit a warning for every repair, truncation, ambiguity, or unsupported
    construct.

The initial supported schema is locked by sanitized fixtures during milestone
one. “Codex JSONL” is not itself a sufficiently precise compatibility promise.

## Repository identity

The importer records:

- repository root name and redacted original path;
- version-control kind;
- starting commit when known;
- ending commit when known;
- initial dirty-state summary;
- relevant worktree or branch identity;
- case-sensitivity behavior;
- platform path semantics.

If a baseline commit is available, the importer may read file content using
`git show` with a fixed argument vector. If only working-tree content is
available, it records that the baseline is observational and hashes every file
used for replay.

The importer never runs repository hooks, builds, tests, package managers, or
commands found in the trace.

## Mutation recovery

Preferred evidence, from strongest to weakest:

1. Explicit before and after content with matching hashes.
2. Explicit patch plus verified before content.
3. Explicit after content plus verified earlier snapshot.
4. Provider-declared mutation without enough content to replay.
5. Inference from final repository state.

Only the first three produce replayable verified or reconstructed mutation
chains. Final working-tree state may help diagnosis but never silently replaces
missing historical content.

Patch application is strict. A failed hunk produces a replay gap and warning;
it does not trigger fuzzy patching in version one.

## Structured outcomes

An importer creates test-case events only when the source provides structured
results or a supported deterministic parser recognizes the command output.
Otherwise the command remains a command with text output.

Outcome parsers are independent, versioned modules. Examples may eventually
cover common machine-readable test formats, but version one requires only the
formats present in the reference fixture.

## Redaction

Redaction occurs before content reaches the canonical writer or raw-record
store. Rules include:

- known credential shapes;
- configured environment-variable names;
- configured path prefixes;
- user-supplied literal and regular-expression rules;
- provider fields designated as sensitive.

Every replacement uses a typed marker such as `[REDACTED:credential]`. The
report counts replacements by rule without storing the secret match.

Raw preservation is opt-in. A preserved raw record is the redacted source
record, not the original bytes.

## Import report

The report is both displayed and stored in metadata:

```text
source records
canonical events
extension events
ignored records by reason
warnings by category
redactions by category
replayable / partial / opaque mutations
timestamp quality counts
unsupported source type names
elapsed time and peak working memory
importer id and version
```

## Determinism

Given identical source bytes, repository baseline, options, and importer
version, canonical chunks and their hashes must be identical. Creation time and
random session identity are excluded from the canonical-content digest and may
differ.

Importers must not depend on locale, machine timezone, directory enumeration
order, hash-map iteration order, network access, or current repository state
after baseline capture.

## Fixture policy

Every supported source variant has:

- a minimal fixture for each event family;
- a malformed-record fixture;
- a redaction fixture;
- a timestamp-repair fixture;
- a replay fixture with known file states;
- a golden canonical summary;
- a license and provenance note.

Real traces are sanitized before entering the repository. Fixtures must not
contain actual credentials, private prompts, usernames, home paths, or source
code from non-test projects.
