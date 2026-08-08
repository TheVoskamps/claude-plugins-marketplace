---
name: probe-fixtures-macos-case-insensitive-fs
description: On macOS APFS, probe fixture names differing only by case (gb.yml vs gB.yml) are ONE file — the collision fakes a "gate lags one call behind" defect in correct code
metadata:
  type: reference
---

Probe fixtures whose names differ only by letter case are the same file on
macOS's default case-insensitive APFS. In PR #243 round 5 a placement-gate
probe used `gb.yml`/`rb.yml` for the bake pair and `gB.yml`/`rB.yml` for the
boot pair; each write to a "boot" fixture silently overwrote its "bake"
sibling, and the gate's verdicts appeared to lag one call behind — the
diagnostics named keys the allegedly-current file never held. That symptom
reads exactly like a caching bug or a wrong-argument-order defect in the code
under review, in a round whose whole brief was hunting a swapped-pair error.

The tell: a function returns the right answer standalone but the "wrong" one
inside a larger flow, and the wrong answer matches a *different* fixture's
content. Before filing that as a finding, print the fixture the callee
actually read (`cat` the path from inside the flow) and check the fixture
names for case-only distinctness. Name fixtures with fully distinct words
(`gbake.yml`/`gboot.yml`), never case pairs.

Related: [[json-payload-via-file-not-echo]] — same class: the probe harness,
not the code under review, manufactures the defect.
