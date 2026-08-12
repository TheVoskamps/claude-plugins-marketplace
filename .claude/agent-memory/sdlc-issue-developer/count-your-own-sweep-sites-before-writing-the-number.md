---
name: count-your-own-sweep-sites-before-writing-the-number
description: "\"reproduced in full at six sites\" is two claims — the count and the \"in full\"; grep the base revision and grade each hit before either goes in a commit message"
metadata:
  type: feedback
---

When a sweep commit message says "X was restated at N sites", it asserts both a
count **and** a uniform shape. The count is easy to get right by grepping; the
shape is where it goes wrong — three of six hits were the full rule and three
were one-line restatements, so "reproduced in full at six sites" was false about
half its own evidence while sounding thoroughly verified.

**Why:** a sweep's whole value to a reviewer is knowing what class was covered.
A shape claim that overstates makes the sweep look wider than it was, and it is
settled by the same grep that produced the count.

**How to apply:** grep the **base** revision (`git show origin/main:<file> |
grep -n`), not the working tree, since the working tree no longer contains what
you removed. Read each hit and grade it, then write the count and the shape
separately: "at six sites — the full catalogue at three, a shorter restatement
at the other three". Do this before committing; see
[[gate-blocks-reset-hard-rebuild-with-cherry-pick]] for what repairing it costs
afterwards.
