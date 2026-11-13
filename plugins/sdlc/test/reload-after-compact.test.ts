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

// The two shapes below are copied from the messages a live `session.compact` hook received: the
// harness keeps a skill's expanded text, and with it the base directory, out of those messages.

/** A slash-typed skill, as the main conversation's message for it arrives. */
function typed(name: string) {
  return {
    role: "user",
    text: `<command-message>${name}</command-message>\n<command-name>/${name}</command-name>\n<command-args>probe</command-args>`,
    toolUses: [],
    handle: "01d26a9a-a4bf-4754-a7a8-be1320593cb7",
  };
}

/** A `Skill` call and its result message, as they arrive. */
function launched(name: string) {
  const result = { success: true, commandName: name };
  const text = `Launching skill: ${name}`;
  return [
    {
      role: "assistant",
      text: "",
      toolUses: [{ tool_use_id: "toolu_1", tool: "Skill", input: { skill: name }, result, text }],
      handle: "928a1507-fc24-41a7-9c82-2871abeb5e39",
    },
    {
      role: "user",
      text: "",
      toolUses: [],
      toolResults: [{ tool_use_id: "toolu_1", text, isError: false, result }],
      handle: "e20daff1-8373-46c4-ab5d-f680f573b720",
    },
  ];
}

test("a slash-typed skill whose message names no base directory is reloaded by its name", async ($, on) => {
  const reads: string[] = [];
  mock.env(on, { HOME });
  on("session.root", () => ({ value: ROOT }));
  on("fs.exists", () => ({ value: false }));
  on("fs.read", ($, e) => {
    reads.push(e.path);
    return { value: "orchestrate skill" };
  });
  on("session.compact", () => ({ messages: [SUMMARY] }));
  const text = reload(
    await $.session.compact({ trigger: "auto", messages: [typed("sdlc:orchestrate")] }),
  );
  const path = reads.find((read) => read.endsWith("/sdlc/skills/orchestrate/SKILL.md"));
  expect(path).toBeDefined();
  expect(text).toContain(block(path!, "orchestrate skill"));
});

test("a Skill call whose result names no base directory is reloaded by its name", async ($, on) => {
  const reads: string[] = [];
  mock.env(on, { HOME });
  on("session.root", () => ({ value: ROOT }));
  on("fs.exists", () => ({ value: false }));
  on("fs.read", ($, e) => {
    reads.push(e.path);
    return { value: "cli interface" };
  });
  on("session.compact", () => ({ messages: [SUMMARY] }));
  const text = reload(
    await $.session.compact({
      trigger: "auto",
      agentId: "adbd5e68bcdff90af",
      messages: launched("sdlc:pr-read-cli-interface"),
    }),
  );
  const path = reads.find((read) => read.endsWith("/sdlc/skills/pr-read-cli-interface/SKILL.md"));
  expect(path).toBeDefined();
  expect(text).toContain(block(path!, "cli interface"));
});

test("a skill with no plugin prefix resolves under the project, then ~/.claude/skills", async ($, on) => {
  const project = `${ROOT}/.claude/skills/mine/SKILL.md`;
  const user = `${HOME}/.claude/skills/theirs/SKILL.md`;
  stub(on, { [project]: "project skill", [user]: "user skill" });
  const messages = [typed("mine"), ...launched("theirs"), typed("compact")];
  const text = reload(await $.session.compact({ trigger: "auto", messages }));
  expect(text).toContain(block(project, "project skill"));
  expect(text).toContain(block(user, "user skill"));
  expect(text).not.toContain("compact/SKILL.md");
});

test("a skill of another plugin with no install recorded is named, and named again", async ($, on) => {
  const entry = "- skill git-tools:git-branch-sync (could not be read: ";
  stub(on, {});
  const first = reload(
    await $.session.compact({ trigger: "auto", messages: launched("git-tools:git-branch-sync") }),
  );
  expect(first).toContain(entry);
  const messages = [SUMMARY, { role: "user", text: first, toolUses: [] }];
  const second = reload(await $.session.compact({ trigger: "auto", messages }));
  expect(second).toContain(entry);
});

test("no agent definition is reloaded for an agent type the conversation spawned", async ($, on) => {
  const reads: string[] = [];
  mock.env(on, { HOME });
  on("session.root", () => ({ value: ROOT }));
  on("fs.exists", () => ({ value: true }));
  on("fs.read", ($, e) => {
    reads.push(e.path);
    return { value: "text" };
  });
  on("session.compact", () => ({ messages: [SUMMARY] }));
  const rule = `${ROOT}/docs/rules/a.md`;
  const messages = [
    spawn("sdlc:issue-developer"),
    spawn("helper"),
    spawn("git-tools:branch-helper"),
    read(rule),
  ];
  const text = reload(await $.session.compact({ trigger: "auto", messages }));
  expect(text).toContain(block(rule, "text"));
  expect(reads.filter((path) => path.includes("/agents/"))).toEqual([]);
  expect(text).not.toContain("issue-developer");
  expect(text).not.toContain("helper");
});

test("a skill of the hook's own plugin with no base directory resolves under the plugin root", async ($, on) => {
  const paths: string[] = [];
  mock.env(on, { HOME });
  on("session.root", () => ({ value: ROOT }));
  on("fs.exists", () => ({ value: false }));
  on("fs.read", ($, e) => {
    paths.push(e.path);
    return { value: "skill" };
  });
  on("session.compact", () => ({ messages: [SUMMARY] }));
  reload(await $.session.compact({ trigger: "auto", messages: launched("sdlc:git-review-pr") }));
  expect(paths.some((path) => path.endsWith("/sdlc/skills/git-review-pr/SKILL.md"))).toBe(true);
  expect(paths.some((path) => path.includes("installed_plugins.json"))).toBe(false);
});

test("a skill of another plugin resolves to its installed version", async ($, on) => {
  // The hook's own plugin root names the marketplace, so the first compaction reads it off the
  // path the hook reads for a skill of its own plugin.
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
  reload(await $.session.compact({ trigger: "auto", messages: launched("sdlc:git-review-pr") }));
  const root = reads[0].slice(0, -"/skills/git-review-pr/SKILL.md".length);
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
  const skillFile = (version: string) => `${cache}/${version}/skills/git-branch-sync/SKILL.md`;
  files[skillFile("0.9.0")] = "installed skill";
  files[skillFile("0.11.0")] = "newer skill";
  const text = reload(
    await $.session.compact({ trigger: "auto", messages: launched("git-tools:git-branch-sync") }),
  );
  expect(text).toContain(block(skillFile("0.9.0"), "installed skill"));
  expect(text).not.toContain("0.11.0");
});

test("a skill of another plugin with no install recorded is named with the error", async ($, on) => {
  stub(on, {});
  const text = reload(
    await $.session.compact({ trigger: "auto", messages: [typed("git-tools:git-branch-sync")] }),
  );
  expect(text).toContain("- skill git-tools:git-branch-sync (could not be read: ");
  expect(text).toContain("installed_plugins.json");
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
  const own = `${SKILLS}/git-review-pr/SKILL.md`;
  const rule = `${ROOT}/docs/rules/hook-event-notes.md`;
  const mainRule = `${ROOT}/docs/rules/main-only.md`;
  stub(on, { [own]: "review skill", [rule]: "notes", [mainRule]: "main" });
  on("session.messages", () => ({
    value: [...skill("sdlc:orchestrate", `${SKILLS}/orchestrate`), read(mainRule)],
  }));
  const messages = [...skill("sdlc:git-review-pr", `${SKILLS}/git-review-pr`), read(rule)];
  const text = reload(await $.session.compact({ trigger: "auto", agentId: "a1", messages }));
  expect(text).toContain(block(own, "review skill"));
  expect(text).toContain(block(rule, "notes"));
  expect(text).not.toContain("orchestrate/SKILL.md");
  expect(text).not.toContain("main-only");
});

// The opening files as the hook's own plugin root resolves them, by their path below that root.
const OPENING = [
  "skills/orchestrate-readiness/SKILL.md",
  "skills/orchestrate/lib/pre-flight.md",
  "skills/orchestrate/lib/plan.md",
];

/**
 * Compacts the transcript `messages` builds and returns the reload text, every file reading as its
 * own path. `messages` receives the orchestrate opening, as the messages that invoke the readiness
 * skill and read the two orchestrate opening files, and a read of one rule file, and places either
 * where the test needs it, or leaves it out.
 */
async function compactOpening($, on, messages): Promise<string> {
  mock.env(on, { HOME });
  on("session.root", () => ({ value: ROOT }));
  on("fs.exists", () => ({ value: false }));
  on("fs.read", ($, e) => ({ value: e.path }));
  on("session.compact", () => ({ messages: [SUMMARY] }));
  const opening = [
    ...launched("sdlc:orchestrate-readiness"),
    read(`${SKILLS}/orchestrate/lib/pre-flight.md`),
    read(`${SKILLS}/orchestrate/lib/plan.md`),
  ];
  const rule = `${ROOT}/docs/rules/a.md`;
  return reload(
    await $.session.compact({
      trigger: "auto",
      messages: messages(opening, read(rule)),
    }),
  );
}

test("orchestrate's opening files are dropped once an Agent call follows its invocation", async ($, on) => {
  const text = await compactOpening($, on, (opening, rule) => [
    typed("sdlc:orchestrate"),
    ...opening,
    spawn("sdlc:issue-developer"),
    rule,
  ]);
  for (const file of OPENING) expect(text).not.toContain(file);
  expect(text).toContain("/docs/rules/a.md (appended below)");
});

test("orchestrate's opening files are reloaded before an Agent call follows its invocation", async ($, on) => {
  const text = await compactOpening($, on, (opening, rule) => [
    ...skill("sdlc:orchestrate", `${SKILLS}/orchestrate`),
    ...opening,
    rule,
  ]);
  for (const file of OPENING) expect(text).toMatch(new RegExp(`/${file} \\(appended below\\)`));
});

test("an Agent call before the orchestrate invocation leaves its opening files live", async ($, on) => {
  const text = await compactOpening($, on, (opening, rule) => [
    spawn("sdlc:pr-monitor"),
    typed("sdlc:orchestrate"),
    ...opening,
    rule,
  ]);
  for (const file of OPENING) expect(text).toMatch(new RegExp(`/${file} \\(appended below\\)`));
});

test("a later orchestrate invocation makes its opening files live until its own Agent call", async ($, on) => {
  const live = await compactOpening($, on, (opening, rule) => [
    typed("sdlc:orchestrate"),
    ...opening,
    spawn("sdlc:issue-developer"),
    ...launched("sdlc:orchestrate"),
    rule,
  ]);
  for (const file of OPENING) expect(live).toMatch(new RegExp(`/${file} \\(appended below\\)`));
});

test("a later orchestrate invocation's own Agent call drops its opening files again", async ($, on) => {
  const text = await compactOpening($, on, (opening, rule) => [
    typed("sdlc:orchestrate"),
    ...opening,
    spawn("sdlc:issue-developer"),
    ...launched("sdlc:orchestrate"),
    rule,
    spawn("sdlc:issue-fixer"),
  ]);
  for (const file of OPENING) expect(text).not.toContain(file);
});

test("an opening file an earlier reload named is dropped once the run is past its opening", async ($, on) => {
  const preFlight = `${SKILLS}/orchestrate/lib/pre-flight.md`;
  const stale = {
    role: "user",
    text: `${MARKER}\n\nFiles, most recently used first:\n- ${preFlight} (appended below)`,
    toolUses: [],
  };
  const text = await compactOpening($, on, (opening, rule) => [
    stale,
    typed("sdlc:orchestrate"),
    spawn("sdlc:issue-developer"),
    rule,
  ]);
  expect(text).not.toContain("pre-flight.md");
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
  const unresolved = "- skill git-tools:git-branch-sync (could not be read: ";
  stub(on, { [rule]: "rule", [later]: "later" });
  const first = reload(
    await $.session.compact({
      trigger: "auto",
      messages: [read(rule), ...launched("git-tools:git-branch-sync")],
    }),
  );
  expect(first).toContain(unresolved);
  const messages = [SUMMARY, { role: "user", text: first, toolUses: [] }, read(later)];
  const second = reload(await $.session.compact({ trigger: "auto", messages }));
  expect(second).toContain(block(rule, "rule"));
  expect(second).toContain(block(later, "later"));
  expect(second).toContain(unresolved);
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
