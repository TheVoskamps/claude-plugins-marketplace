#!/usr/bin/env bash
# Test, lint and cross-compile the permission gate, then install the
# committed binaries under ../bin/<goos>-<goarch>/.
#
# Usage: rebuild-binaries.sh
#
# Run it from any directory, on a working tree `git status --porcelain`
# reports clean and with no gitignored file in this module directory, where
# the build would read it as it reads a tracked one. It refuses any other tree
# before it tests or builds, and it also refuses a GOFLAGS value from the
# environment or the go env file, whose -modfile or -overlay would point the
# build at a file outside git. Every go command runs with GOWORK=off, so no
# go.work file, inside the repo or above it, adds to the build. Together these
# build the binaries from committed source. Every target is pure Go with CGo
# disabled, so all of them cross-compile from one host and none is built at
# plugin load time.
#
# Every binary is built with -buildvcs=false, so it embeds no vcs.revision,
# vcs.time or vcs.modified stamp, and a rebuild of the same source with the
# same Go toolchain matches the committed binary byte for byte at any later
# commit, the amend that adds the binaries included.
#
# Each binary is built into a gitignored scratch directory and copied into
# ../bin/ only once every arch is built, so a failed build leaves ../bin/ as
# it was.
#
# Exit status: 0 when the binaries are installed; 1 on any failure — a dirty
# working tree, an ignored file in this directory, a GOFLAGS value, a test, vet, lint, format or build step, or a git or
# filesystem step — with nothing copied into ../bin/ unless a mkdir, copy or
# chmod into it fails, which leaves in place every arch copied before the failure;
# 2 on a usage error.

set -euo pipefail

# The <goos>-<goarch> set hooks.json selects from by `uname`: macOS on Apple
# Silicon, WSL2, and claude-vm guests (Debian on Apple Silicon). A platform
# missing here has no binary, and hooks.json denies every gated tool call on it.
TARGETS=(darwin-arm64 linux-amd64 linux-arm64)

fail() {
  echo "rebuild-binaries.sh: $1" >&2
  exit 1
}

if [ "$#" -ne 0 ]; then
  echo "rebuild-binaries.sh: takes no arguments." >&2
  exit 2
fi

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || fail "cannot resolve the script's own directory"
bin_dir=$(cd "$module_dir/../bin" && pwd) || fail "cannot resolve $module_dir/../bin"
repo_root=$(git -C "$module_dir" rev-parse --show-toplevel) ||
  fail "git rev-parse --show-toplevel failed in $module_dir"
scratch="$repo_root/.claude/tmp/rebuild-binaries"

cd "$module_dir" || fail "cannot cd to $module_dir"

tree_status=$(git -C "$repo_root" status --porcelain) || fail "git status --porcelain failed in $repo_root"
if [ -n "$tree_status" ]; then
  printf '%s\n' "$tree_status" >&2
  fail "the working tree is not clean: commit every change, then run again"
fi

# `git status --porcelain` omits ignored files, and the go commands below
# compile an ignored .go file here, or embed an ignored file a //go:embed
# pattern names, as they would a tracked one.
ignored=$(git -C "$module_dir" status --porcelain --ignored=matching -- .) ||
  fail "git status --porcelain --ignored failed in $module_dir"
if [ -n "$ignored" ]; then
  printf '%s\n' "$ignored" >&2
  fail "gitignored files are present in $module_dir: remove them, then run again"
fi

export GOWORK=off
goflags=$(go env GOFLAGS) || fail "go env GOFLAGS failed"
if [ -n "$goflags" ]; then
  fail "GOFLAGS is set to '$goflags': unset it, in the environment and with go env -u GOFLAGS, then run again"
fi

go test ./... || fail "go test failed"
go vet ./... || fail "go vet failed"
# golangci-lint discovers the repo-root .golangci.yml upward from here.
golangci-lint run || fail "golangci-lint run reported issues"
fmt_diff=$(golangci-lint fmt --diff) || fail "golangci-lint fmt --diff failed"
if [ -n "$fmt_diff" ]; then
  printf '%s\n' "$fmt_diff" >&2
  fail "golangci-lint fmt --diff reported unformatted source"
fi

rm -rf "$scratch" || fail "cannot remove $scratch"
for target in "${TARGETS[@]}"; do
  goos=${target%-*}
  goarch=${target#*-}
  out="$scratch/$target/permission-gate"
  GOOS=$goos GOARCH=$goarch CGO_ENABLED=0 go build -trimpath -buildvcs=false -o "$out" . ||
    fail "go build failed for $target"
done

for target in "${TARGETS[@]}"; do
  # A target new to TARGETS has no directory under ../bin/ yet.
  mkdir -p "$bin_dir/$target" || fail "creating $bin_dir/$target failed"
  cp "$scratch/$target/permission-gate" "$bin_dir/$target/permission-gate" ||
    fail "copying the $target binary into $bin_dir failed"
  chmod 755 "$bin_dir/$target/permission-gate" || fail "chmod of the $target binary failed"
done
# The binaries are installed, so a scratch directory left behind is reported
# rather than turned into a failure.
rm -rf "$scratch" || echo "rebuild-binaries.sh: could not remove $scratch" >&2

echo "rebuild-binaries.sh: installed ${TARGETS[*]} under $bin_dir"
