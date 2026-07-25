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
