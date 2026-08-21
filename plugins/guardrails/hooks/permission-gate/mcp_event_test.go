package main

import "testing"

// §10 / §2: read-only MCP tools allowed; write MCP tools defer; unknown defers
// (an MCP tool NAME substring is not grounds for a human click).
func TestMCPClassification(t *testing.T) {
	cases := []struct {
		name string
		tool string
		want Bucket
	}{
		{"snapshot read-only", "mcp__playwright__browser_snapshot", BucketAllow},
		{"console messages read-only", "mcp__playwright__browser_console_messages", BucketAllow},
		{"network requests read-only", "mcp__playwright__browser_network_requests", BucketAllow},
		{"ide diagnostics read-only", "mcp__ide__getDiagnostics", BucketAllow},
		{"list read-only", "mcp__github__list_pull_requests", BucketAllow},
		{"get read-only", "mcp__github__get_issue", BucketAllow},
		{"merge mutation", "mcp__github__merge_pull_request", BucketDefer},
		{"create mutation", "mcp__github__create_release", BucketDefer},
		{"branch protection mutation", "mcp__github__update_branch_protection", BucketDefer},
		{"unknown tool defers", "mcp__weird__frobnicate", BucketDefer},
	}
	for _, c := range cases {
		ev := &Event{ToolName: c.tool, ToolInput: []byte(`{}`)}
		d := classifyMCP(ev)
		if d.Bucket != c.want {
			t.Errorf("%s (%s): got %q (%s), want %q", c.name, c.tool, d.Bucket, d.Reason, c.want)
		}
	}
}

// §10: an uncertain operation lands in DEFER, and — the half that
// matters — never in ALLOW. The bucket is asserted exactly so a future
// widening of the read-only sets cannot quietly turn an unknown tool into an
// allow while this test keeps passing on a "not ask" check.
func TestUnknownMCPDefersAndCarriesAnalysis(t *testing.T) {
	ev := &Event{ToolName: "mcp__svc__do_something_weird", ToolInput: []byte(`{}`)}
	d := classifyMCP(ev)
	if d.Bucket != BucketDefer {
		t.Errorf("unknown MCP must DEFER; got %q", d.Bucket)
	}
	if d.Operation == "" || d.Reason == "" {
		t.Errorf("unknown-MCP defer must carry the gate's analysis for the §7 log; got op=%q reason=%q",
			d.Operation, d.Reason)
	}
}

// Event parsing fail-closed cases.
func TestParseEventFailClosed(t *testing.T) {
	for _, raw := range []string{"", "{", "{}", `{"tool_input":{}}`} {
		if _, err := parseEvent([]byte(raw)); err == nil {
			t.Errorf("parseEvent(%q) should error (fail-closed)", raw)
		}
	}
}

func TestParseEventAgentTypeNormalization(t *testing.T) {
	ev, err := parseEvent([]byte(`{"tool_name":"Bash","subagent_type":"issue-fixer","tool_input":{"command":"ls"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if !ev.isSubagent() {
		t.Errorf("subagent_type should mark event as subagent")
	}
}

func TestMainSessionNotSubagent(t *testing.T) {
	for _, at := range []string{"", "main", "general-purpose"} {
		ev := &Event{AgentType: at}
		if ev.isSubagent() {
			t.Errorf("agent_type %q should be treated as main session", at)
		}
	}
}

// A Bash event missing its command never ALLOWs. It defers with the
// read error as its analysis, rather than spending a human click on an event
// that carries no command for a human to adjudicate.
func TestBashNoCommandNeverAllows(t *testing.T) {
	ev := &Event{ToolName: "Bash", ToolInput: []byte(`{}`), CWD: "/tmp"}
	d := classify(ev)
	if d.Bucket != BucketDefer {
		t.Errorf("bash with no command must defer; got %q", d.Bucket)
	}
	if d.Operation != "bash:unreadable" || d.Reason == "" {
		t.Errorf("unreadable-bash defer must be loggable; got op=%q reason=%q", d.Operation, d.Reason)
	}
}

// Unknown tool defers (no opinion).
func TestUnknownToolDefers(t *testing.T) {
	ev := &Event{ToolName: "SomeFutureTool", ToolInput: []byte(`{}`)}
	if classify(ev).Bucket != BucketDefer {
		t.Errorf("unknown tool should defer")
	}
}
