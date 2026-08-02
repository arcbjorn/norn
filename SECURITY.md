# Security policy

Norn opens logs, repositories, patches, command output, and trace containers
that may be malformed or malicious. All imported data is untrusted. The full
threat model is in [docs/08-security.md](docs/08-security.md); this file covers
how to report a problem with it.

## Reporting a vulnerability

Report privately through
[GitHub security advisories](https://github.com/arcbjorn/norn/security/advisories/new),
which is the preferred channel. Do not open a public issue for a security
problem.

**Do not attach an unredacted trace, session log, or repository.** A trace
carries prompts, file content, command output, and paths from the machine it
was recorded on, and an issue attachment is public the moment it is posted. If
reproducing the problem needs a trace, say so and a private channel will be
arranged — or better, reduce it to a synthetic fixture like the ones in
`tests/fixtures/hostile`, which contain no real content by construction.

A useful report names the affected input, the observed behaviour, and the
property from docs/08 that it violates.

## Expectations

This is a pre-release project maintained by one person. Reports are
acknowledged within a week. There is no patch-time commitment and no supported
release yet, because there has been no release: the only supported version is
the current `master`.

That will change before a tagged release, and this file will change with it.

## What counts as a vulnerability

The non-negotiable properties in docs/08 are the bar. Opening or replaying a
trace must never:

- execute a command, script, binary, hook, plugin, or macro;
- checkout or mutate a repository;
- resolve a path outside the selected repository boundary;
- fetch a URL or contact a provider;
- load executable code embedded in a trace;
- render arbitrary HTML or active document content;
- expose unredacted secrets in an export by default.

A crash, an unbounded allocation, or a hang while parsing untrusted input also
counts — a parser handling hostile logs is a denial-of-service surface even
when it cannot be made to execute anything.

Anything reachable from a trace file or a session log is in scope. Deliberate
local actions the user configures, such as the editor-open command in docs/08,
are not.

## Known limitations

These are documented rather than defects, and reporting them tells us nothing
new:

**Redaction is best-effort.** docs/08 states plainly that "Norn cannot
guarantee automatic discovery of every secret." The rules catch recognisable
credential shapes; a secret that looks like ordinary prose will survive. Review
an export before sharing it.

**Import runs `git`.** It is the one stage that runs another program, always
with a fixed argument vector built from validated input. Nothing from a trace
becomes an argument. If you find a path where it does, that is a vulnerability.

**No cryptographic authenticity.** A `.norn` file carries checksums and a
content digest, which detect corruption and casual tampering. They are not
signatures: anyone who can rewrite the file can recompute them. Treat a trace
from an untrusted source as untrusted input — which is what Norn does.
