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

// classifyMCP branches on the MCP tool name (§2). Read-only MCP tools ALLOW;
// known write/mutation tools (GitHub MCP merges, release/branch-protection/
// settings mutations, and the like) ASK — a human should confirm a remote
// mutation. Anything we can't confidently call read-only ASKs rather than
// allows (ask-default).
func classifyMCP(ev *Event) Decision {
	name := ev.ToolName
	// The tool segment is everything after the second "__".
	tool := name
	if i := strings.LastIndex(name, "__"); i >= 0 {
		tool = name[i+2:]
	}
	lt := strings.ToLower(tool)

	// Explicit high-risk mutation verbs / nouns on remote services → ASK.
	for _, frag := range mcpMutationFragments {
		if strings.Contains(lt, frag) {
			return ask("mcp:mutation", fmt.Sprintf(
				"MCP tool '%s' looks like a remote-state mutation (matched %q). "+
					"Confirm this is intended before it runs.", name, frag))
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

	// Unknown MCP tool: ask-default (fail toward human decision).
	return ask("mcp:unknown", fmt.Sprintf(
		"MCP tool '%s' is not on the gate's read-only allow set; escalating to a human decision (ask-default).", name))
}

// mcpMutationFragments are substrings that, when present in an MCP tool name,
// indicate a remote-state mutation that must be confirmed by a human.
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
