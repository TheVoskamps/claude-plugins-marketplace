---
name: widened-enumeration-trailing-clause
description: When a round widens an enumeration ("the four X" -> "every X"), the sentences AFTER it that qualify the old, narrower set are the half-applied remainder — re-read the whole paragraph, not the list.
metadata:
  type: feedback
---

A fixer that widens an enumeration edits the list and the sentence that
introduces it. The clauses *downstream* of the list — the "except", "only",
"unless" qualifiers that were written against the narrow set — keep the old
scope and now read as false for the widened one.

**Why:** issue #157 round 5 widened claude-vm's comma-exposure list from "the
four built-in `--device` lines" to "**every** vfkit argument that embeds a
host path" (adding the EFI store, the disk, the console log and the gvproxy
socket). Two sentences later the paragraph still said the failure is always
loud "except a path that itself spelled a second `sharedDir=`" — a key that
exists only on the shares, not on the four newly-added arguments. Every
assertion around it was true; the exception clause silently narrowed the
widened claim back.

**How to apply:** after any list-widening edit, read to the end of the
paragraph and grep the old narrow token (`sharedDir=`, `the four`, the old
helper name) in the same file. Then settle the widened version by running it:
`vfkit` is installed on this host, so a claim about how it parses an argument
is one throwaway invocation away — give it a nonexistent kernel/EFI store so
nothing boots, and read the parse error (`unknown option for virtio-net
devices: …`). A repeated key inside one option string parses without
complaint on v0.6.4; a bare comma does not. Related:
[[diagnostic-detail-claims]], [[no-blanket-predicate-over-a-list]].
