# auto-mode-tools

## Neither skill reads the other's state

`tune-auto-mode` never reads the facts file, and
`personalize-auto-mode` never reads or writes the state directory, the
ledger and `provenance.yml` included, and there is no ordering
contract between them. Keep it so: a change that has one skill read what the other
writes ends that independence.

## Keep the tuner's state out of `settings.json`

Claude Code strips `//`-prefixed keys whenever it rewrites
`settings.json` itself, so the ledger and the provenance live in the
state directory, and the `autoMode` block carries only `environment`,
`allow`, `soft_deny` and `hard_deny`.

## The personalizer leaves the revision unbumped

After a `personalize-auto-mode` rewrite, `provenance.yml` still names
the revision the tuner last wrote. Leave that mismatch: bumping the
revision would claim a critique round the personalizer never ran, and
repairing it would break the independence above.

## Tests

Run the sink's test after changing `payload/sink.py`:

```bash
/usr/bin/python3 plugins/auto-mode-tools/payload/test/sink-test.py
```

It drives the real sink over loopback and never runs
`claude auto-mode critique`.
