---
name: orchestrate-analysis
description: Report where an /sdlc:orchestrate run's wall-clock time went for one PR — a begin-to-end timeline, totals, per-round review phases, every wait on the human, and each ruling on a theorem or on a fixer-brief finding that names none — by running the read-only sdlc-orchestrate-analysis script.
---

# Orchestrate Analysis

Run `sdlc-orchestrate-analysis` over one PR and present what it prints.
The script owns the whole report — which sources it reads, how it
attributes time, and what it names as missing — so this skill adds
nothing to its output, and reads no source of its own to supplement
it.

## Invocation

```text
/sdlc:orchestrate-analysis <PR>
```

`<PR>` is the PR number, with or without a leading `#`. If `$ARGUMENTS`
carries none, ask which PR before running anything.

## Process

1. Run the script from the repository the PR belongs to, spelled as a
   bare name:

   ```bash
   sdlc-orchestrate-analysis <PR>
   ```

2. **Exit 0** — print its stdout to the user unchanged. It is Markdown,
   and its "Missing sources" section is part of the report, not an
   error.

3. **Non-zero exit** — the script produced no report. Show its stderr
   verbatim and stop; do not assemble a report from any other source.
