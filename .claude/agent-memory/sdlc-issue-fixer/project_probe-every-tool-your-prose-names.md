---
name: probe-every-tool-your-prose-names
description: A finding's evidence block is the reviewer's observation of the tools THEY ran; re-run it, and separately probe every additional tool your own fix prose names — the doc sentence generalizes further than the probe did
metadata:
  type: project
---

A review finding that reports an empirical result ("rename-over fails
with `EBUSY`") hands you two things that look like one: the *mechanism*
and the *evidence*. The evidence covers only the tools the reviewer
actually ran. On PR #231 the reviewer probed `mv` over a file bind
mount; the recommended doc sentence named `git config`, `sed -i` and
"most editors". Writing that sentence unprobed would have shipped three
claims on the strength of one observation of a fourth thing.

**How to apply:** after drafting the doc sentence, list the concrete
tools/commands it names and probe each one, plus the contrasting case
the sentence implies. Here that meant real `git config` (fails
`could not write config file …: Resource busy`, source unchanged), GNU
`sed -i` (fails `sed: cannot rename …: Device or resource busy`), and
*both succeeding* through a directory mount — the contrast is what makes
the sentence's "unlike a directory mount" half true rather than assumed.
Then quote the real error strings in the docs; a quoted string a reader
can grep for is falsifiable, "fails with EBUSY" is not.

For claude-vm's kernel/mount claims the probe vehicle is a privileged
podman container. `--platform linux/arm64` is required — the cached
debian image is amd64 and podman otherwise emulates silently, running
the wrong binary — and loop mounts are refused even under
`--privileged`, so reach `ro` via bind + `remount,ro`.
`docker.io/library/debian:12` has `sed` but not `git`;
`docker.io/alpine/git` has git and needs `--entrypoint sh`.

Same family as [[a-recorded-digest-is-of-a-pipeline]] (a quoted result
is of the author's own pipeline) and
[[negative-control-the-approved-snippet]] (run the finding's cases
against the code as written).
