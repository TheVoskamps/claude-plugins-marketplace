package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestMain runs the package's tests against a fixture home, so no test reads
// the driving machine's own ~/.config/guardrails/config.yml or writes its
// evolution log. The fixture's config sets nothing but
// `redirect-bash-file-work: off`, so a test of another track run from a linked
// worktree gets that track's verdict rather than the file-work redirect's,
// which is on there by default. A test that needs another config, or a home of
// another shape, installs its own with t.Setenv.
func TestMain(m *testing.M) {
	os.Exit(runWithEmptyHome(m))
}

// goHomeEnv are the Go toolchain locations that default to paths under the
// home. They are pinned to the driving machine's values before the home moves,
// so a test that builds the gate keeps its build and module caches.
var goHomeEnv = []string{"GOCACHE", "GOMODCACHE", "GOPATH"}

// runWithEmptyHome is TestMain's body, split out so the fixture home is
// removed after the run.
func runWithEmptyHome(m *testing.M) int {
	out, err := exec.Command("go", append([]string{"env"}, goHomeEnv...)...).Output()
	if err != nil {
		fmt.Fprintln(os.Stderr, "go env:", err)
		return 1
	}
	values := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	if len(values) != len(goHomeEnv) {
		fmt.Fprintf(os.Stderr, "go env printed %d values for %d names\n", len(values), len(goHomeEnv))
		return 1
	}
	for i, name := range goHomeEnv {
		os.Setenv(name, values[i])
	}

	dir, err := os.MkdirTemp("", "permission-gate-home-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer os.RemoveAll(dir)
	home := filepath.Join(dir, "home")
	configDir := filepath.Join(home, operatorCarveOutConfigDirName, operatorCarveOutPluginDir)
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	config := fmt.Sprintf("schema-version: %d\n%s: %s\n", operatorCarveOutSchemaVersion, redirectBashFileWorkKey,
		fileWorkOff)
	if err := os.WriteFile(filepath.Join(configDir, operatorCarveOutFileName), []byte(config), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	os.Setenv("HOME", home)
	os.Unsetenv(logEnvVar)
	return m.Run()
}
