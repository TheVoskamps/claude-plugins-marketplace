# claude-vm config gates

## A schema change starts at the key table

`CLAUDE_VM_CONFIG_KEYS` in `payload/lib/config.sh` is the schema: the
merge's list keys, the placement gates' sub-key sets, the scalar
defaults and `bin/claude-vm-config-keys` all derive from it, and the
config wizards interview from that script's output. A new key, or a
key's new file, type, shape or default, is a table row. What a key
means, and a new load-time gate or a caveat about a value a wizard
offers, goes in `skills/claude-vm/config-keys.md`, which the wizards
read; a gate that runs over the merged global and repo lists is a
collision the per-repo wizard has to warn about.

Adding a list-shaped row silently disarms any `has()` presence gate on
that key, with nothing to error, because the merge then prunes it.

## The merge destroys presence, three ways

`claude_vm_merge_config` ends in `claude_vm_prune_empty_skeleton`, and
a key written in an empty spelling reaches the merged document absent:

- pass 1 deletes a list key whose union is empty — a valueless key,
  `[]` and `""` all merge to an empty list;
- pass 2 deletes an empty map wherever it sits, including inside a list
  element, so `key: {}` escapes for every key, list or not;
- a valueless non-list key reaches the merged document as a genuine
  null, which `!= null` reads as absent — except that a global file with
  no repo file deep-merges it against the empty document and coerces it
  to `''`, so the verdict depends on the layer.

So a gate asking whether the operator wrote a key asks `has()` of each
raw file, which also lets the diagnostic name the file. Never carve a
key out of the prune instead: the prune exists so no consumer reads
presence off a merged document.

Grade every existing gate on any change, not only the one touched: grep
`payload/` for `has(`, `!= null` and `== null`, and check each hit
against every prune route above. Pin a verdict by driving
`claude_vm_merge_config` in the launcher's own argument shape, and
cover every spelling — valueless, `[]`, `""`, `{}` — for every key: the
escapes differ by key, and fixture-only batteries stayed green while
the launcher let the config through.

## Reading a TSV record

Helpers move multi-field records as yq `@tsv` lines over a fixed-length
array, which always writes every separator. A tab is IFS whitespace, so
`IFS=$'\t' read -r a b c` collapses a run of tabs and strips a leading
one: an empty middle or leading field vanishes and the later fields
shift, silently. Read the whole line with `IFS= read -r` and split it
with `${rec%%$TAB*}` and `${rec#*$TAB}`. Skip a wholly empty record
before judging its fields: an empty result set is one empty line, not
zero bytes. Guard each emitted field with `// ""` so an omitted key and
an explicit `""` reach the reader as the same empty field rather than
the string `null`.

Pin a split by running the real reader against records from the real
emitter, asserting on the values it produced, beside a negative control
that rebuilds the collapsing `read` from the same captured lines. No
shipped reader uses the collapsing form; only the tests' negative
controls do.

## A mount tag has more roles than its charset admits

`claude_vm_check_mounts` derives its tag rejections from every position
the tag is consumed verbatim in: vfkit's `mountTag=` inside the
comma-delimited `--device` string; a bare argument in the guest's
`mount -t virtiofs -o rw <tag> <path>`; a path component of
`<CLAUDE_VM_GUEST_MOUNT_ROOT>/<tag>`, `$MOUNT_WRAP_DIR/<tag>` and
`<CLAUDE_VM_GUEST_WRAP_MOUNT>/<tag>`; and a `mounts.tsv` field. The
charset check covers only the first two, so `.` and `..` (not path
components) and a leading `-` (read as a `mount` option, which on
util-linux 2.38.1 exits 0 having mounted nothing) have their own arms.

That list is the grading instrument. Code that gives the tag a new
position — a filename, another argument slot, an interpolated string —
adds an arm when the position rejects something the existing ones
accept. Adding an arm updates every surface that restates the rejection
set: `lib/config.sh`'s block comment, `claude-vm.sh`'s
`claude_vm_check_mounts` call-site comment, `config-boot.example.yml`'s
`tag:` bullet, and `skills/claude-vm/config-keys.md`.
