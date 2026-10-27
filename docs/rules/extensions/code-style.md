# Code Style — this repo

## For Authors

## For Authors and Checkers

### Code lints clean under the linter named for its format

Every Code file the diff touches passes the linter named here for its
format, each run as the binary on `PATH`:

- Shell script — `shellcheck`, `bash -n` for syntax, and `shfmt` for
  formatting.
- Go — `golangci-lint run` to check and `golangci-lint fmt` to rewrite
  files with the formatters, run from the Go module's directory under
  the repo-root `.golangci.yml`. `gosec`, `gofmt` and `goimports` run
  inside `golangci-lint`, not as binaries of their own; `go vet` stays
  available directly.
- GitHub Actions workflow — `actionlint`.
- YAML — `yamllint`.
- JSON and JSONC — `biome lint`; `oxfmt` alone formats them.
- TOML — `tombi`.
- CloudFormation template — `cfn-lint`.
- JS, TS, JSX and TSX — `oxlint`.
- Formatting of JS, TS, JSX, TSX, JSON, JSONC, YAML, TOML and HTML —
  `oxfmt`.

A linter absent from `PATH` is a stop-and-report, never an install.
