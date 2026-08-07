---
name: verify-cleanup-claims-not-just-behavior
description: A comment asserting "X is cleaned up on exit" is a structural claim about cleanup(), settled by one grep -- and in claude-vm it is usually FALSE, because cleanup() shreds only $CREDS_DIR and deliberately retains $RUN.
metadata:
  type: feedback
---

While implementing issue #157 I wrote a comment on a new per-run directory:
"Under $RUN so it is cleaned up with the rest of the run state." The behavior
around it was fully verified -- real build, real boot, every acceptance
criterion observed -- and the sentence was still false.

**Why:** `claude-vm.sh`'s `cleanup()` removes `$CREDS_DIR` and decides the guest
image clone's fate. It does NOT remove `$RUN`: the run dir is deliberately
retained so `/claude-vm-diff` and `/claude-vm-apply-*` can read it afterward.
"Run state is cleaned up on exit" is a plausible-sounding default assumption
about any tool with a `cleanup()` trap, and it is exactly backwards here.

**How to apply:** treat every lifetime claim -- "cleaned up on exit",
"removed by the trap", "shredded", "discarded", "temporary" -- as a structural
assertion needing a grep, in the same class as "the only caller" and "funnelled
through a single helper". One `grep -n 'rm -rf "\$VAR"' <file>` settles it. The
trap is that these sentences sit next to code you DID test, so the verified
behavior lends them unearned credibility; no test fails on a wrong lifetime
claim in a comment.

Same class as the general obligation in the agent definition ("Verify the claims
in your own prose"); this is the specific instance that bit, recorded because
lifetime claims are easy to write on autopilot when adding any new per-run
artifact. Related: [[claude-vm-four-file-config-and-per-run-clone]] documents
what cleanup() actually does with the image clone.
