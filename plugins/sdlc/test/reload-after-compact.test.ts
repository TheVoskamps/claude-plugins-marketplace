import { expect, mock, test } from "claude-code/testing";

import { BUDGET_KEY, DEFAULT_BUDGET, MARKER } from "../hooks/reload-after-compact.ts";

const HOME = "/home/u";
const ROOT = "/work";
const SUMMARY = {
  role: "user",
  text: "This session is being continued from a previous conversation.",
  toolUses: [],
};
const SKILLS = "/plugins/sdlc/0.1.0/skills";

/**
 * Stubs everything the hook reaches: `files` is the file system by absolute path, a path in
 * `refused` rejects its read with the given reason, and `next(e)` resolves to the summary alone.
 */
function stub(on, files: Record<string, string>, refused: Record<string, string> = {}, env = {}) {
  mock.env(on, { HOME, ...env });
  on("session.root", () => ({ value: ROOT }));
  on("fs.exists", ($, e) => ({ value: e.path in files || e.path in refused }));
  on("fs.read", ($, e) => {
    if (e.path in refused) return { deny: refused[e.path] };
    return e.path in files ? { value: files[e.path] } : { deny: `ENOENT: no such file, ${e.path}` };
  });
  on("session.compact", () => ({ messages: [SUMMARY] }));
}

function assistant(...toolUses) {
  return { role: "assistant", text: "", toolUses };
}

function skill(name: string, base: string) {
  return [
    assistant({
      tool_use_id: name,
      tool: "Skill",
      input: { skill: name },
      text: `Launching skill: ${name}`,
    }),
    {
      role: "user",
      text: `Base directory for this skill: ${base}\n\nThe skill's text.`,
      toolUses: [],
    },
  ];
}

function spawn(type: string) {
  return assistant({
    tool_use_id: type,
    tool: "Agent",
    input: { subagent_type: type, prompt: "go" },
    text: "done",
  });
}

function read(path: string) {
  return assistant({
    tool_use_id: path,
    tool: "Read",
    input: { file_path: path },
    text: "contents",
  });
}

/** The text of the message the hook appended, after checking the summary still leads. */
function reload(result): string {
  expect(result.messages[0]).toEqual(SUMMARY);
  expect(result.messages).toHaveLength(2);
  expect(result.messages[1].text.startsWith(MARKER)).toBe(true);
  return result.messages[1].text;
}

function block(path: string, content: string): string {
  return `<file path="${path}">\n${content}\n</file>`;
}

test("a skill the main conversation invoked is reloaded whole", async ($, on) => {
  const path = `${SKILLS}/orchestrate/SKILL.md`;
  const content = "# orchestrate\n" + "x".repeat(60000);
  stub(on, { [path]: content });
  const result = await $.session.compact({
    trigger: "auto",
    messages: skill("sdlc:orchestrate", `${SKILLS}/orchestrate`),
  });
  const text = reload(result);
  expect(text).toContain(block(path, content));
  expect(text).toContain(`- ${path} (appended below)`);
});

test("every agent type the main conversation spawned is reloaded, and no other", async ($, on) => {
  const own = `${SKILLS.replace("/skills", "")}/agents/issue-developer.md`;
  const project = `${ROOT}/.claude/agents/helper.md`;
  stub(on, { [own]: "developer definition", [project]: "helper definition" });
  const messages = [
    ...skill("sdlc:orchestrate", `${SKILLS}/orchestrate`),
    spawn("sdlc:issue-developer"),
    spawn("helper"),
    spawn("general-purpose"),
  ];
  const text = reload(await $.session.compact({ trigger: "auto", messages }));
  expect(text).toContain(block(own, "developer definition"));
  expect(text).toContain(block(project, "helper definition"));
  expect(text).not.toContain("theorem-disprover");
  expect(text).not.toContain("general-purpose");
});

test("an agent of the hook's own plugin with no skill loaded resolves under the plugin root", async ($, on) => {
  const paths: string[] = [];
  mock.env(on, { HOME });
  on("session.root", () => ({ value: ROOT }));
  on("fs.exists", () => ({ value: false }));
  on("fs.read", ($, e) => {
    paths.push(e.path);
    return { value: "definition" };
  });
  on("session.compact", () => ({ messages: [SUMMARY] }));
  reload(await $.session.compact({ trigger: "auto", messages: [spawn("sdlc:pr-monitor")] }));
  expect(paths.some((path) => path.endsWith("/sdlc/agents/pr-monitor.md"))).toBe(true);
});

test("an agent of another plugin with no skill loaded resolves to its highest cached version", async ($, on) => {
  const listed: string[] = [];
  stub(on, {});
  on("fs.list", ($, e) => {
    listed.push(e.path);
    return {
      value: [
        { name: "0.9.0", kind: "dir", size: 0, mtimeMs: 0, isLink: false },
        { name: "0.11.0", kind: "dir", size: 0, mtimeMs: 0, isLink: false },
      ],
    };
  });
  const text = reload(
    await $.session.compact({ trigger: "auto", messages: [spawn("git-tools:branch-helper")] }),
  );
  expect(listed).toHaveLength(1);
  expect(listed[0].startsWith(`${HOME}/.claude/plugins/cache/`)).toBe(true);
  expect(listed[0].endsWith("/git-tools")).toBe(true);
  expect(text).toContain(`${listed[0]}/0.11.0/agents/branch-helper.md (could not be read:`);
});

test("a rule file read is reloaded, and CLAUDE.md, ~/.claude/rules and other files are not", async ($, on) => {
  const rule = `${ROOT}/docs/rules/verification-playbook.md`;
  const global = `${HOME}/.claude/docs/rules/code-style.md`;
  stub(on, { [rule]: "playbook", [global]: "code style" });
  const messages = [
    read(rule),
    read(global),
    read(`${ROOT}/CLAUDE.md`),
    read(`${HOME}/.claude/CLAUDE.md`),
    read(`${HOME}/.claude/rules/core-principles.md`),
    read(`${ROOT}/README.md`),
    read(`${ROOT}/skills/lib/script.sh`),
  ];
  const text = reload(await $.session.compact({ trigger: "auto", messages }));
  expect(text).toContain(block(rule, "playbook"));
  expect(text).toContain(block(global, "code style"));
  expect(text).not.toContain("CLAUDE.md");
  expect(text).not.toContain("core-principles");
  expect(text).not.toContain("README.md");
  expect(text).not.toContain("script.sh");
});

test("a subagent's compaction reloads what its own transcript loaded", async ($, on) => {
  const own = `${SKILLS.replace("/skills", "")}/agents/theorem-disprover.md`;
  const rule = `${ROOT}/docs/rules/hook-event-notes.md`;
  stub(on, { [own]: "disprover definition", [rule]: "notes" });
  on("session.messages", () => ({
    value: [...skill("sdlc:orchestrate", `${SKILLS}/orchestrate`), spawn("sdlc:issue-developer")],
  }));
  const messages = [
    ...skill("sdlc:git-review-pr", `${SKILLS}/git-review-pr`),
    spawn("sdlc:theorem-disprover"),
    read(rule),
  ];
  const text = reload(await $.session.compact({ trigger: "auto", agentId: "a1", messages }));
  expect(text).toContain(block(own, "disprover definition"));
  expect(text).toContain(block(rule, "notes"));
  expect(text).not.toContain("orchestrate/SKILL.md");
  expect(text).not.toContain("issue-developer");
});

test("past the budget, the most recently used are appended and the rest listed", async ($, on) => {
  const [a, b, c] = ["a", "b", "c"].map((name) => `${ROOT}/docs/rules/${name}.md`);
  stub(on, {
    [a]: "a".repeat(40),
    [b]: "b".repeat(40),
    [c]: "c".repeat(40),
    [`${ROOT}/.sdlc/repo-config.yml`]: `schema-version: 1\n${BUDGET_KEY}: 20\n`,
  });
  const text = reload(
    await $.session.compact({ trigger: "auto", messages: [read(a), read(b), read(c)] }),
  );
  expect(text).toContain(block(c, "c".repeat(40)));
  expect(text).toContain(block(b, "b".repeat(40)));
  expect(text).not.toContain("a".repeat(40));
  expect(text).toContain(`- ${a} (not appended: read it before acting on it)`);
  expect(text.indexOf(`- ${c} `)).toBeLessThan(text.indexOf(`- ${b} `));
  expect(text).toContain("budget of 20 tokens");
});

test("the budget is 100000 tokens when no tier sets it", async ($, on) => {
  const [a, b, c] = ["a", "b", "c"].map((name) => `${ROOT}/docs/rules/${name}.md`);
  stub(on, { [a]: "a".repeat(4), [b]: "b".repeat(200000), [c]: "c".repeat(200000) });
  const text = reload(
    await $.session.compact({ trigger: "auto", messages: [read(a), read(b), read(c)] }),
  );
  expect(DEFAULT_BUDGET).toBe(100000);
  expect(text).toContain(`budget of ${DEFAULT_BUDGET} tokens`);
  expect(text).toContain(`- ${c} (appended below)`);
  expect(text).toContain(`- ${b} (appended below)`);
  expect(text).toContain(`- ${a} (not appended: read it before acting on it)`);
});

test("a higher tier's budget wins over a lower one's", async ($, on) => {
  const rule = `${ROOT}/docs/rules/a.md`;
  stub(on, {
    [rule]: "rule",
    [`${HOME}/.config/sdlc/user-config.yml`]: `schema-version: 1\n${BUDGET_KEY}: 5\n`,
    [`${ROOT}/.sdlc/user-config.yml`]: `schema-version: 1\n${BUDGET_KEY}: 7 # mine\n`,
  });
  const text = reload(await $.session.compact({ trigger: "auto", messages: [read(rule)] }));
  expect(text).toContain("budget of 7 tokens");
});

test("XDG_CONFIG_HOME locates the global tier", async ($, on) => {
  const rule = `${ROOT}/docs/rules/a.md`;
  stub(
    on,
    { [rule]: "rule", [`/xdg/sdlc/user-config.yml`]: `schema-version: 1\n${BUDGET_KEY}: 9\n` },
    {},
    { XDG_CONFIG_HOME: "/xdg" },
  );
  const text = reload(await $.session.compact({ trigger: "auto", messages: [read(rule)] }));
  expect(text).toContain("budget of 9 tokens");
});

for (const [name, config] of [
  ["zero", `schema-version: 1\n${BUDGET_KEY}: 0\n`],
  ["a quoted string", `schema-version: 1\n${BUDGET_KEY}: "500"\n`],
  ["a float", `schema-version: 1\n${BUDGET_KEY}: 1.5\n`],
  ["no schema-version", `${BUDGET_KEY}: 50\n`],
  ["malformed YAML", `schema-version: 1\nthis is not yaml\n`],
]) {
  test(`a tier holding ${name} falls back to the default and names the path`, async ($, on) => {
    const rule = `${ROOT}/docs/rules/a.md`;
    const tier = `${ROOT}/.sdlc/repo-config.yml`;
    stub(on, {
      [rule]: "rule",
      [tier]: config,
      [`${ROOT}/.sdlc/user-config.yml`]: `schema-version: 1\n${BUDGET_KEY}: 3\n`,
    });
    const text = reload(await $.session.compact({ trigger: "auto", messages: [read(rule)] }));
    expect(text).toContain(`budget of ${DEFAULT_BUDGET} tokens`);
    expect(text).toContain(`- ${tier}: `);
    expect(text).toContain(block(rule, "rule"));
  });
}

test("a tier that cannot be read falls back to the default and names the path and error", async ($, on) => {
  const rule = `${ROOT}/docs/rules/a.md`;
  const tier = `${HOME}/.config/sdlc/user-config.yml`;
  stub(on, { [rule]: "rule" }, { [tier]: "EACCES: permission denied" });
  const text = reload(await $.session.compact({ trigger: "auto", messages: [read(rule)] }));
  expect(text).toContain(`budget of ${DEFAULT_BUDGET} tokens`);
  expect(text).toContain(`- ${tier}: `);
  expect(text).toContain("EACCES: permission denied");
  expect(text).toContain(block(rule, "rule"));
});

test("a file that cannot be read is named with its error, and the compaction completes", async ($, on) => {
  const gone = `${ROOT}/docs/rules/gone.md`;
  const rule = `${ROOT}/docs/rules/a.md`;
  stub(on, { [rule]: "rule" });
  const text = reload(
    await $.session.compact({ trigger: "manual", messages: [read(gone), read(rule)] }),
  );
  expect(text).toContain(`- ${gone} (could not be read: `);
  expect(text).toContain("ENOENT");
  expect(text).toContain(block(rule, "rule"));
});

test("a second compaction reloads what the first one reloaded", async ($, on) => {
  const rule = `${ROOT}/docs/rules/a.md`;
  const later = `${ROOT}/docs/rules/b.md`;
  stub(on, { [rule]: "rule", [later]: "later" });
  const first = reload(await $.session.compact({ trigger: "auto", messages: [read(rule)] }));
  const messages = [SUMMARY, { role: "user", text: first, toolUses: [] }, read(later)];
  const second = reload(await $.session.compact({ trigger: "auto", messages }));
  expect(second).toContain(block(rule, "rule"));
  expect(second).toContain(block(later, "later"));
  expect(second.indexOf(`- ${later} `)).toBeLessThan(second.indexOf(`- ${rule} `));
});

test("nothing is appended when the transcript loaded nothing", async ($, on) => {
  stub(on, {});
  const result = await $.session.compact({
    trigger: "auto",
    messages: [read(`${ROOT}/src/main.go`)],
  });
  expect(result.messages).toEqual([SUMMARY]);
});

test("a skipped compaction passes through untouched", async ($, on) => {
  mock.env(on, { HOME });
  on("session.compact", () => ({ skip: "blocked" }));
  const result = await $.session.compact({
    trigger: "manual",
    messages: [read(`${ROOT}/docs/rules/a.md`)],
  });
  expect(result).toEqual({ skip: "blocked" });
});

test("a reload already in the result is replaced, not repeated", async ($, on) => {
  const rule = `${ROOT}/docs/rules/a.md`;
  const later = `${ROOT}/docs/rules/b.md`;
  const stale = {
    role: "user",
    text: `${MARKER}\n\nFiles, most recently used first:\n- ${rule} (appended below)`,
    toolUses: [],
  };
  mock.env(on, { HOME });
  on("session.root", () => ({ value: ROOT }));
  on("fs.exists", () => ({ value: false }));
  on("fs.read", ($, e) => ({ value: e.path === rule ? "rule" : "later" }));
  on("session.compact", () => ({ messages: [SUMMARY, stale] }));
  const text = reload(
    await $.session.compact({ trigger: "auto", messages: [read(rule), read(later)] }),
  );
  expect(text).toContain(block(rule, "rule"));
  expect(text).toContain(block(later, "later"));
});
