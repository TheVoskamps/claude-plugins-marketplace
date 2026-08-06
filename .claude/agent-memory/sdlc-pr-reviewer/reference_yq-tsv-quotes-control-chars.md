---
name: yq-tsv-quotes-control-chars
description: yq v4's @tsv QUOTES a field containing a tab or newline, so a control character in a claude-vm config value cannot split or inject a manifest record — measure it before carrying a "record injection" worry forward
metadata:
  type: reference
---

`yq` v4.53.3's `@tsv` operator wraps a field in double quotes when the value
contains a tab or a newline, rather than emitting the raw byte. So for
claude-vm's `claude_vm_mount_specs` (and its sibling emitters), a `path:`
carrying a control character reaches the validator as
`'"/opt<TAB>/etc/ld.so.preload"'` — leading `"`, therefore not absolute,
therefore rejected — and a block-scalar newline cannot split one entry into a
second, unvalidated record.

**Why:** across three rounds of PR #231 I carried "a literal tab in a `path:`
splits the guest record" as a standing follow-up, and in round 3 asserted it
"is accepted host-side". Measuring it in round 4 (feed the YAML through the
real emitter and read `od -c` of the output) showed the opposite: both the tab
and the newline shapes are rejected, and the record-injection route the
newline would have opened does not exist. A worry repeated across rounds
without being measured becomes review furniture.

**How to apply:** when a hand-split TSV pipeline makes you wonder whether an
operator-supplied value can forge a separator, run the real emitter and dump
the bytes (`claude_vm_mount_specs "$boot.yml" | od -c`) before writing a word
about it. Also re-check it if the repo ever changes yq major version — the
quoting is yq's behavior, not a property of the consumer's hand split. And
correct your own earlier rounds out loud when the measurement contradicts
them: see [[regrade-own-verified-and-check-round-narratives]].
