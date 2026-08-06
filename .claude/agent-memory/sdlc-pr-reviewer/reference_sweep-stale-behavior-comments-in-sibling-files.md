---
name: sweep-stale-behavior-comments-in-sibling-files
description: when reviewing a behavior-change bugfix (e.g. claude-vm launcher exec-shell -> child-shell), grep the WHOLE plugin for the OLD behavior shape; the developer's prose-doc pass reliably updates narrative sections but misses terse file-tree annotations and comments in files the commit didn't otherwise touch.
metadata:
  type: reference
---

When a commit changes a runtime behavior and updates the docs for it,
do not trust that the doc pass was complete. Grep the entire plugin for
strings describing the OLD behavior shape, not just the files in the
diff.

Concrete instance (claude-vm PR #180, round 5, commit 6c1d1b0): the
abnormal-path post-mortem shell changed from `exec bash -l` (shell
REPLACES launcher, guest never powers off) to a CHILD `bash -l`
followed by `kill -s RTMIN+4 1` (poweroff after the shell exits). The
developer correctly rewrote the narrative sections of `payload/README.md`
(the two prose paragraphs) and `skills/claude-vm/SKILL.md`, and the
source + tests were all correct. But two stale descriptions of the OLD
shape survived:

- `payload/README.md`'s `test/` file-tree annotation still read
  `nonzero -> exec a root login shell on hvc1` (terse comment, easy to
  miss in a prose-focused pass).
- `payload/provisioners/podman-mkosi.sh` (a file the commit never
  touched) carried a getty-drop-in comment: "the launcher does NOT
  power off; it exec's an interactive root LOGIN SHELL" -- directly
  contradicting the shipped, test-asserted behavior (boot-launcher-test
  asserts "does not exec the post-mortem shell").

**Why:** a behavior change is a *class* of stale references
(core-principles #8, "sweep the class"). The prose-doc pass and the
diff files are not the whole class -- sibling files that merely
*describe* the changed behavior (provisioner comments, file-tree
annotations, error strings) are part of it too. This is the reviewer
counterpart of the doc-updater's own
[[claude-vm-config-redesign-stale-comment-classes]] lesson.

**How to apply:** for any behavior-change bugfix round, before
approving, grep the plugin for a short verbatim string from the OLD
behavior (here: `exec a root`, `does NOT power off`, `exec.s an
interactive`). A comment describing the old broken shape as CURRENT is
a real defect (grade Medium -- it contradicts shipped behavior in an
edited plugin, not optional polish), even when it lives in a file the
commit didn't touch. Provisioner-comment fixes carry NO guest-byte
rebuild cost (host-side build script), so recommending them is cheap.

`payload/README.md` and `skills/claude-vm/SKILL.md` carry large blocks
of near-verbatim parallel prose (boot-launcher description,
credential/seed install, install-health check). A sweep commit
routinely converts the phrase in one and leaves the identical twin in
the other stale -- after listing the converted phrases in the diff,
grep the SAME phrase in BOTH files. A hit in one but not the other is
a sweep-the-class miss regardless of an "all sites fixed" claim.

**Round 6 reinforcement (commit 8ffe678, the DEDICATED sweep commit):**
a commit whose entire job was "sweep stale exec'd-shell prose" STILL
missed three more of the identical class. Do not assume a sweep commit
was exhaustive just because its message claims "all three sites fixed".
Re-run the grep yourself against the branch tip; grade what remains.
The three misses were instructive about *where* the class hides:

- The SAME file the sweep edited (`build-guest-image.sh`) had two more
  hits the sweep didn't touch -- one at the `emit_boot_launcher()`
  definition-site header comment, one inside the emitted heredoc's own
  file-header. A sweep that fixes the detailed "exit-status contract"
  block routinely misses the terser one-line restatements elsewhere in
  the same function/file.
- A TEST file header (`boot-launcher-test.sh`) restated the old
  behavior as the current contract ("do NOT power off; `exec` a shell")
  while the test's own assertion code below it checked the NEW behavior
  (`shell--l,rtmin4-...` = shell THEN poweroff). A header that
  contradicts its file's own assertions is a real Medium.
- The legitimately-historical hit (a `Bumped 16 -> 17` changelog
  stanza) SHOULD keep the old wording -- it describes what that rev
  did. Distinguish "changelog stanza for a past rev" (leave alone) from
  "present-tense `As of #NNN it does X`" (must match shipped code).
For an inside-the-heredoc miss, the rev-bump question recurs: fixing it
is free at rev N only while NO rev-N image has been built anywhere yet
(unbuilt draft PR, sole operator); once a rev-N image exists, changing
heredoc bytes needs a rev bump. If the fix lands in the same
pre-first-build window, no bump; if deferred past a build, demand one.

**When the narrowed claim is a HELPER's coverage sentence (#229,
PR #232 round 4), the misses are structural and predictable.** A round
that discovers a helper covers less than its comment says (there:
`pathFlagValueRefs` covers getopt's spellings, not pflag's `-F=FILE`)
scopes the sentence at the function it was reading. Three sites then
reliably survive, and all three are worth grepping before calling the
class swept:

- **The WRAPPER directly above/below it.** `pathFlagValues` is a
  four-line wrapper over `pathFlagValueRefs` with its own docstring
  ("in every spelling the utility accepts") — and it is the half with
  the callers (`utilitySpec.operands`, the in-repo-write track), while
  only the gh track calls the qualified `Refs` half. Run
  `grep -n "helperName(" *.go` and scope the sentence on whichever
  name the other tracks actually call.
- **The spec FIELD DOC of every other track that feeds the helper**
  (`inRepoWriteSpec.pathValueFlags`, `utilitySpec.pathValueFlags`) —
  usually in a file the PR never touches.
- **The README's sibling paragraph for the older track.** The new
  track's paragraph gets the qualifier; the read-track paragraph 300
  lines earlier keeps the unqualified one.

Cheapest tell that the class is still open: **grep the doc-updater's
own `.claude/agent-memory/` note from the same commit range.** On #232
it recorded the lesson quoting the exact sentence — "a shared helper's
doc comment that says `every spelling the utility accepts`" — that it
had left unedited in the code. The note names the site.

**Closing the class (#232 round 5) takes two things the fix round does
not supply.** A sweep round reports the sites it fixed AND a list it
"deliberately left alone because each already names its parser or
enumerates its spellings". Both halves need independent work:

- **Re-run the slurp on a SYNONYM axis.** The class gets named after
  one noun ("spelling"), so the first slurp only proves no copy
  survives under that noun. Run a second pass for
  `(every|all|any|each) … (forms?|ways?|variants?)` before certifying
  exhaustion. On #232 that axis was clean (21 hits, all other
  mechanisms), but a clean second axis is the evidence, not an
  assumption.
- **Grade the left-alone list yourself, and check each exemption's
  claim is TRUE, not just scoped.** "in every spelling gh accepts"
  names its parser, which exempts it from the prose class — but it is
  also a behavioural assertion, so trace the walk against every
  spelling before passing it (`-F X`, `-FX`, `-F=X`, `--f X`,
  `--f=X`, cluster tail, `--`).
- **A candidate site your OWN prior note names may carry no claim at
  all.** This file listed `utilitySpec.pathValueFlags` beside
  `inRepoWriteSpec.pathValueFlags`; at the tip the former makes no
  coverage claim (it enumerates the glued-vs-separate contrast
  concretely instead), so the correct verdict was "untouched, and
  rightly". Re-read the site before counting it as a miss.

One more cheap adjudication when the qualifier is a parser claim: run
the real getopt program. `grep -f=/nonexistent/xyz.txt README.md`
answers `grep: =/nonexistent/xyz.txt: No such file or directory`,
which settles "getopt keeps the `=` in the value, pflag strips it" in
one command instead of by citation.
