# Product

## One sentence

Norn is a native desktop application that lets developers replay, inspect, and
debug coding-agent sessions as evidence-linked changes to a repository.

## Problem

Coding agents can perform hundreds or thousands of actions in one session. A
terminal transcript records those actions but does not make them understandable:

- edits are separated from the prompts and reads that motivated them;
- commands and test failures disappear into long streams of output;
- the repository only shows its final state;
- retries obscure the first point at which behavior diverged;
- multiple agents and sub-processes interleave events;
- provider-specific logs use incompatible schemas.

When the final result is wrong, the developer must manually reconstruct what
happened. Norn turns that reconstruction into the primary interface.

## Product promise

Given a supported trace and repository, Norn answers four questions:

1. What happened, in exact order?
2. What did the repository look like at any selected moment?
3. Which earlier actions are plausible contributors to this outcome?
4. What evidence supports each connection shown by the application?

Norn distinguishes recorded facts from inferred relationships. It never labels
an action as the cause of a failure when the trace only establishes proximity
or dependency.

## Primary user

The first user is a developer who regularly delegates non-trivial repository
work to command-line coding agents and needs to understand failed, expensive,
or surprising sessions.

Secondary users are:

- coding-agent authors debugging orchestration and tool behavior;
- engineering teams reviewing agent-generated changes;
- researchers comparing execution strategies;
- maintainers preparing a compact bug report from a large session.

## Core jobs

### Diagnose a regression

Select the first failing test, see which files and symbols changed since its
last passing run, then inspect the responsible edit candidates in context.

### Understand an unfamiliar session

Open a shared trace and obtain a faithful overview without reading the original
transcript line by line.

### Compare attempts

See how an agent's failed approach differs from its later successful repair,
including reads, edits, commands, duration, and repeated errors.

### Produce a review artifact

Export a bounded report containing the relevant timeline slice, diffs, command
results, and evidence links without sharing unrelated prompts or secrets.

## Version-one scope

Version one will:

- run as a native macOS desktop application;
- import one documented Codex JSONL trace family;
- normalize provider events into Norn's canonical model;
- support traces with at least 100,000 events;
- reconstruct text-file state without modifying the source repository;
- show a timeline, diff viewer, repository map, and event inspector;
- correlate edits with later command and test outcomes;
- preserve raw source records for audit when the user opts in;
- work fully offline after import;
- export a self-contained diagnostic report.

Linux is the second supported platform. Windows is allowed by the architecture
but is not part of the first-release gate.

## Non-goals

Version one is not:

- an agent runner or orchestrator;
- an IDE or source editor;
- a general-purpose log viewer;
- a production observability service;
- an evaluation leaderboard;
- a replacement for Git;
- a system for exposing hidden model reasoning;
- a cloud account, synchronization service, or team dashboard.

Norn may open the user's editor at a file and line, but it does not own editing.
It may display model-provided summaries, but it does not claim access to private
chain-of-thought.

## Principles

### Evidence before interpretation

Every derived relationship carries a reason and confidence. The user can always
navigate from an inference back to the source events.

### Time is the primary axis

Files, commands, tests, and graph nodes are projections of a session timeline.
The selected time controls every panel.

### The repository is never the replay surface

Replay occurs in an in-memory virtual repository. Opening a trace must never
checkout a commit, overwrite a file, invoke a hook, or run a command.

### Native performance is a feature

Interaction must remain immediate on sessions large enough to be painful in a
terminal. Import can take seconds; scrubbing cannot.

### Adapters isolate unstable inputs

Provider trace formats will change. Provider-specific assumptions stop at the
import boundary and never leak into rendering or analysis.

### Useful without AI

Import, replay, search, correlation, and visualization are deterministic. Any
future model-assisted explanation must be optional and visibly identified.

## Success criteria

The first release succeeds when a developer can import a real failed session
and identify the first relevant divergence faster than by reading its transcript.

Quantitative targets:

- import 100,000 typical events in under 10 seconds on a current Apple Silicon
  laptop;
- reopen an imported trace in under 2 seconds;
- maintain a responsive 60 Hz interaction loop while scrubbing;
- update synchronized panels within 50 ms of a timeline selection;
- reconstruct any indexed text file within 100 ms at the p95;
- use less than 1 GiB of memory for the 100,000-event reference fixture;
- produce identical canonical output when importing the same source twice.

The budgets are release targets, not claims about unfinished software.
