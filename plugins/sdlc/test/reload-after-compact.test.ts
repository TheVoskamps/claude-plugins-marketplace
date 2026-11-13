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

test("each of several Skill calls in one message is reloaded from its own expansion", async ($, on) => {
  const [first, second] = ["orchestrate", "git-review-pr"].map((name) => `${SKILLS}/${name}`);
  stub(on, { [`${first}/SKILL.md`]: "first skill", [`${second}/SKILL.md`]: "second skill" });
  const call = (name: string) => ({ tool_use_id: name, tool: "Skill", input: { skill: name } });
  const expansion = (base: string) => ({
    role: "user",
    text: `Base directory for this skill: ${base}\n\nThe skill's text.`,
    toolUses: [],
  });
  const messages = [
    assistant(call("sdlc:orchestrate"), call("sdlc:git-review-pr")),
    expansion(first),
    expansion(second),
  ];
  const text = reload(await $.session.compact({ trigger: "auto", messages }));
  expect(text).toContain(block(`${first}/SKILL.md`, "first skill"));
  expect(text).toContain(block(`${second}/SKILL.md`, "second skill"));
});

test("a skill invoked as a slash command is reloaded", async ($, on) => {
  const path = `${SKILLS}/orchestrate/SKILL.md`;
  stub(on, { [path]: "orchestrate" });
  const messages = [
    {
      role: "user",
      text: `<command-name>/sdlc:orchestrate</command-name>\nBase directory for this skill: ${SKILLS}/orchestrate\n\nThe skill's text.`,
      toolUses: [],
    },
  ];
  const text = reload(await $.session.compact({ trigger: "manual", messages }));
  expect(text).toContain(block(path, "orchestrate"));
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

test("an agent of another plugin with no skill loaded resolves to its installed version", async ($, on) => {
  // The hook's own plugin root names the marketplace, so the first compaction reads it off the
  // path the hook reads for an agent of its own plugin.
  const reads: string[] = [];
  const files: Record<string, string> = {};
  mock.env(on, { HOME });
  on("session.root", () => ({ value: ROOT }));
  on("fs.exists", () => ({ value: false }));
  on("fs.read", ($, e) => {
    reads.push(e.path);
    return e.path in files ? { value: files[e.path] } : { deny: `ENOENT: ${e.path}` };
  });
  on("session.compact", () => ({ messages: [SUMMARY] }));
  reload(await $.session.compact({ trigger: "auto", messages: [spawn("sdlc:pr-monitor")] }));
  const root = reads[0].slice(0, -"/agents/pr-monitor.md".length);
  const marketplace = root.split("/").at(-3);
  const cache = `${HOME}/.claude/plugins/cache/${marketplace}/git-tools`;
  const install = (version: string, projectPath?: string) => ({
    scope: projectPath === undefined ? "user" : "local",
    ...(projectPath === undefined ? {} : { projectPath }),
    installPath: `${cache}/${version}`,
    version,
  });
  files[`${HOME}/.claude/plugins/installed_plugins.json`] = JSON.stringify({
    version: 2,
    plugins: {
      [`git-tools@${marketplace}`]: [install("0.11.0", "/elsewhere"), install("0.9.0")],
    },
  });
  files[`${cache}/0.9.0/agents/branch-helper.md`] = "installed definition";
  files[`${cache}/0.11.0/agents/branch-helper.md`] = "newer definition";
  const text = reload(
    await $.session.compact({ trigger: "auto", messages: [spawn("git-tools:branch-helper")] }),
  );
  expect(text).toContain(block(`${cache}/0.9.0/agents/branch-helper.md`, "installed definition"));
  expect(text).not.toContain("0.11.0");
});

test("an agent of another plugin with no install recorded is named with the error", async ($, on) => {
  stub(on, {});
  const text = reload(
    await $.session.compact({ trigger: "auto", messages: [spawn("git-tools:branch-helper")] }),
  );
  expect(text).toContain("- agent git-tools:branch-helper (could not be read: ");
  expect(text).toContain("installed_plugins.json");
});

test("an agent with no plugin prefix resolves under ~/.claude/agents when the project has none", async ($, on) => {
  const user = `${HOME}/.claude/agents/mine.md`;
  const shadowed = `${HOME}/.claude/agents/helper.md`;
  const project = `${ROOT}/.claude/agents/helper.md`;
  stub(on, { [user]: "user definition", [shadowed]: "shadowed", [project]: "project definition" });
  const text = reload(
    await $.session.compact({
      trigger: "auto",
      messages: [spawn("mine"), spawn("helper"), spawn("general-purpose")],
    }),
  );
  expect(text).toContain(block(user, "user definition"));
  expect(text).toContain(block(project, "project definition"));
  expect(text).not.toContain("shadowed");
  expect(text).not.toContain("general-purpose");
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
  ["a signed zero", `schema-version: 1\n${BUDGET_KEY}: +0\n`],
  ["a quoted string", `schema-version: 1\n${BUDGET_KEY}: "500"\n`],
  ["a float", `schema-version: 1\n${BUDGET_KEY}: 1.5\n`],
  ["no schema-version", `${BUDGET_KEY}: 50\n`],
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

for (const [name, config, budget] of [
  ["a signed integer", `schema-version: 1\n${BUDGET_KEY}: +50000\n`, 50000],
  ["an integer with leading zeros", `schema-version: 1\n${BUDGET_KEY}: 007\n`, 7],
  [
    "unlisted keys with quoted and dotted names",
    `schema-version: 1\n"odd key": x\nmerge.wait: skip\n'other': 2\n${BUDGET_KEY}: 11\n`,
    11,
  ],
  [
    "a line that is no key of its own",
    `schema-version: 1\nthis is not yaml\n${BUDGET_KEY}: 13\n`,
    13,
  ],
] as const) {
  test(`a tier holding ${name} sets the budget`, async ($, on) => {
    const rule = `${ROOT}/docs/rules/a.md`;
    stub(on, { [rule]: "rule", [`${ROOT}/.sdlc/repo-config.yml`]: config });
    const text = reload(await $.session.compact({ trigger: "auto", messages: [read(rule)] }));
    expect(text).toContain(`budget of ${budget} tokens`);
    expect(text).not.toContain("Config:");
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
  const agent = "- agent git-tools:branch-helper (could not be read: ";
  stub(on, { [rule]: "rule", [later]: "later" });
  const first = reload(
    await $.session.compact({
      trigger: "auto",
      messages: [read(rule), spawn("git-tools:branch-helper")],
    }),
  );
  expect(first).toContain(agent);
  const messages = [SUMMARY, { role: "user", text: first, toolUses: [] }, read(later)];
  const second = reload(await $.session.compact({ trigger: "auto", messages }));
  expect(second).toContain(block(rule, "rule"));
  expect(second).toContain(block(later, "later"));
  expect(second).toContain(agent);
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

test("a reload already in the result is replaced, and what it named is reloaded", async ($, on) => {
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
  const text = reload(await $.session.compact({ trigger: "auto", messages: [read(later)] }));
  expect(text).toContain(block(rule, "rule"));
  expect(text).toContain(block(later, "later"));
});

test("a reload in the result is kept when there is nothing fresh to reload", async ($, on) => {
  const stale = { role: "user", text: `${MARKER}\n\nNothing named.`, toolUses: [] };
  mock.env(on, { HOME });
  on("session.root", () => ({ value: ROOT }));
  on("fs.exists", () => ({ value: false }));
  on("session.compact", () => ({ messages: [SUMMARY, stale] }));
  const result = await $.session.compact({
    trigger: "auto",
    messages: [read(`${ROOT}/src/main.go`)],
  });
  expect(result.messages).toEqual([SUMMARY, stale]);
});
