# claude-harness-tools

## A verb that reads captures belongs in this plugin

The plugin name is a bucket. A later verb that reads captures — a diff of
two captures, a replay — lands in this plugin under its existing name, and
nothing already here is renamed to make room for it.

## Every shell script runs under the bash 3.2 macOS ships

No associative arrays, no `${var,,}`, and an empty array expanded through
`${a[@]+"${a[@]}"}`.

## Run both suites, and verify against their negative controls

Run each suite from the repo root:

```bash
/usr/bin/python3 plugins/claude-harness-tools/test/ch-proxy-test.py
/bin/bash plugins/claude-harness-tools/test/ch-capture-test.sh
```

A green run measures the command only while its negative control still
fails. The proxy's control is a copy with the response fully buffered and
the server single-threaded, against which the streaming and concurrency
cases fail. The launcher's control is the launcher with its trap removed,
against which every proxy-stopped case fails. A change to those cases or
to the code they cover is checked against its control.
