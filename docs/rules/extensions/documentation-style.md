# Documentation Style — this repo

## Rules

### No prose the diff adds narrates the failure the change removes

Documentation here states the behavior at head. Prose a fix PR adds
carries the standing constraint in present tense — not "calling X
panicked", not a before-and-after inventory of the shapes the old code
mishandled, not a comparison measured against the pre-fix source. A
single worked verdict a test pins is a statement about current behavior
and stays.

### Every paragraph the diff edits is reflowed whole

Every paragraph the diff inserts into or cuts out of is rewrapped
across its full width afterwards, leaving no short line mid-paragraph
where the edit landed.
