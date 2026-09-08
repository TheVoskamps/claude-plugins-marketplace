package main

import (
	"fmt"
	"strings"
)

// isMCPTool reports whether a tool name is an MCP tool. MCP tools are named
// mcp__<server>__<tool>.
func isMCPTool(name string) bool {
	return strings.HasPrefix(name, "mcp__")
}

// classifyMCP branches on the MCP tool name. Read-only MCP tools ALLOW;
// everything else DEFERS. The mutation branch and the unknown-tool
// branch are both judgment-middle calls: the classification here is a
// SUBSTRING match on a tool NAME, which says nothing about what the call
// actually targets, so a downstream judge reading the arguments and the
// session context is strictly better placed than a prompt. Neither branch ever
// reaches the allow track.
func classifyMCP(ev *Event) Decision {
	name := ev.ToolName
	// The tool segment is everything after the second "__".
	tool := name
	if i := strings.LastIndex(name, "__"); i >= 0 {
		tool = name[i+2:]
	}
	lt := strings.ToLower(tool)

	// Explicit high-risk mutation verbs / nouns on remote services → DEFER.
	for _, frag := range mcpMutationFragments {
		if strings.Contains(lt, frag) {
			return deferJudgment("mcp:mutation", fmt.Sprintf(
				"MCP tool '%s' looks like a remote-state mutation (matched %q).", name, frag))
		}
	}

	// Read-only verb prefixes → ALLOW.
	for _, frag := range mcpReadOnlyPrefixes {
		if strings.HasPrefix(lt, frag) {
			return allow(fmt.Sprintf("MCP tool '%s' is a read-only operation", name))
		}
	}
	for _, frag := range mcpReadOnlyContains {
		if strings.Contains(lt, frag) {
			return allow(fmt.Sprintf("MCP tool '%s' is a read-only operation", name))
		}
	}

	// Unknown MCP tool: the gate has no read-only grounds, so it withholds the
	// allow and hands the call on.
	return deferJudgment("mcp:unknown", fmt.Sprintf(
		"MCP tool '%s' is not on the gate's read-only allow set, so it has no positive grounds to bless it.", name))
}

// mcpMutationFragments are substrings that, when present in an MCP tool name,
// indicate a remote-state mutation, which the gate cannot bless on its own.
var mcpMutationFragments = []string{
	"merge", "create", "update", "delete", "remove", "add", "set",
	"close", "reopen", "edit", "push", "write", "upload", "dispatch",
	"rerun", "cancel", "approve", "request_review", "submit", "publish",
	"protection", "transfer", "rename", "fork", "enable", "disable",
	"assign", "lock", "unlock", "comment", "review",
}

// mcpReadOnlyPrefixes are verb prefixes that indicate a read-only MCP tool.
var mcpReadOnlyPrefixes = []string{
	"get_", "list_", "search_", "read_", "view_", "fetch_", "describe_",
}

// mcpReadOnlyContains are substrings that indicate a read-only MCP tool even
// when not a leading verb (e.g. browser_snapshot, browser_console_messages).
var mcpReadOnlyContains = []string{
	"snapshot", "console_messages", "network_requests", "diagnostics",
	"_status", "_logs", "screenshot",
}
