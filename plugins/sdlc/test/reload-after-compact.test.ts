import { expect, mock, test } from "claude-code/testing";

import { BUDGET_KEY, DEFAULT_BUDGET, MARKER, MIN_BUDGET } from "../hooks/reload-after-compact.ts";

const HOME = "/home/u";
const ROOT = "/work";
const SESSION = "5f0c3e1a-7b2d-4c8e-9a10-2b3c4d5e6f70";
const SUMMARY = {
  role: "user",
  text: "This session is being continued from a previous conversation.",
  toolUses: [],
};
const SKILLS = "/plugins/sdlc/0.1.0/skills";
const STATE = `${HOME}/.local/state/sdlc/reload-after-compact/${SESSION}`;

type Disk = {
  /** A file's text, `{ deny }` to refuse its read, or `undefined` when it does not exist. */
  read?: (path: string) => string | { deny: string } | undefined;
  /** Whether a file exists; by default, whether `read` returns anything for it. */
  exists?: (path: string) => boolean;
  /** A reason to refuse every write with, or `undefined` to let each land. */
  refuseWrite?: string;
  env?: Record<string, string>;
  /** What `next(e)` resolves to; the summary alone by default. */
  compacted?: object;
};

/**
 * Stubs everything the hook reaches, with `disk` as the file system behind an in-memory store of
 * the files the hook writes, which the returned map holds by path.
 */
function host(on, disk: Disk = {}): Record<string, string> {
  const written: Record<string, string> = {};
  const read = disk.read ?? (() => undefined);
  const exists = disk.exists ?? ((path: string) => read(path) !== undefined);
  mock.env(on, { HOME, ...disk.env });
  on("session.root", () => ({ value: ROOT }));
  on("session.id", () => ({ value: SESSION }));
  on("fs.exists", ($, e) => ({ value: e.path in written || exists(e.path) }));
  on("fs.read", ($, e) => {
    if (e.path in written) return { value: written[e.path] };
    const text = read(e.path);
    if (text === undefined) return { deny: `ENOENT: no such file, ${e.path}` };
    return typeof text === "string" ? { value: text } : text;
  });
  on("fs.write", ($, e) => {
    if (disk.refuseWrite !== undefined) return { deny: disk.refuseWrite };
    written[e.path] = e.text;
    return { value: undefined };
  });
  on("session.compact", () => disk.compacted ?? { messages: [SUMMARY] });
  return written;
}

/** `host` over `files` by absolute path, with a path in `refused` refusing its read. */
function stub(on, files: Record<string, string>, refused: Record<string, string> = {}, env = {}) {
  return host(on, {
    read: (path) => (path in refused ? { deny: refused[path] } : files[path]),
    env,
  });
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
  host(on, {
    read: (path) => {
      reads.push(path);
      return "orchestrate skill";
    },
    exists: () => false,
  });
  const text = reload(
    await $.session.compact({ trigger: "auto", messages: [typed("sdlc:orchestrate")] }),
  );
  const path = reads.find((read) => read.endsWith("/sdlc/skills/orchestrate/SKILL.md"));
  expect(path).toBeDefined();
  expect(text).toContain(block(path!, "orchestrate skill"));
});

test("a Skill call whose result names no base directory is reloaded by its name", async ($, on) => {
  const reads: string[] = [];
  host(on, {
    read: (path) => {
      reads.push(path);
      return "cli interface";
    },
    exists: () => false,
  });
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

test("every command tag in one message is reloaded", async ($, on) => {
  const [mine, theirs] = ["mine", "theirs"].map(
    (name) => `${ROOT}/.claude/skills/${name}/SKILL.md`,
  );
  stub(on, { [mine]: "mine", [theirs]: "theirs" });
  const message = {
    role: "user",
    text: "<command-name>/mine</command-name>\n<command-name>/theirs</command-name>",
    toolUses: [],
  };
  const text = reload(await $.session.compact({ trigger: "auto", messages: [message] }));
  expect(text).toContain(block(mine, "mine"));
  expect(text).toContain(block(theirs, "theirs"));
});

test("a command tag and its base directory in the next message are recorded once, by the file", async ($, on) => {
  const base = `${HOME}/.claude/plugins/cache/market/git-tools/0.11.0/skills/git-branch-sync`;
  stub(on, { [`${base}/SKILL.md`]: "branch sync" });
  const messages = [
    typed("git-tools:git-branch-sync"),
    {
      role: "user",
      text: `Base directory for this skill: ${base}\n\nThe skill's text.`,
      toolUses: [],
    },
  ];
  const text = reload(await $.session.compact({ trigger: "auto", messages }));
  expect(text).toContain(block(`${base}/SKILL.md`, "branch sync"));
  expect(text).not.toContain("skill git-tools:git-branch-sync");
  expect(text.split("git-branch-sync/SKILL.md (")).toHaveLength(2);
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

test("a skill with no plugin prefix in neither skills directory resolves in an installed plugin", async ($, on) => {
  const cache = `${HOME}/.claude/plugins/cache/market`;
  const file = `${cache}/issues/0.14.1/skills/issue-view/SKILL.md`;
  stub(on, {
    [`${HOME}/.claude/plugins/installed_plugins.json`]: JSON.stringify({
      version: 2,
      plugins: {
        "git-tools@market": [{ scope: "user", version: "0.11.0" }],
        "issues@market": [{ scope: "user", version: "0.14.1" }],
      },
    }),
    [file]: "issue view",
  });
  const text = reload(
    await $.session.compact({
      trigger: "auto",
      messages: [typed("issue-view"), typed("compact")],
    }),
  );
  expect(text).toContain(block(file, "issue view"));
  expect(text).not.toContain("compact/SKILL.md");
  expect(text).not.toContain("could not be read");
});

test("a skill of another plugin with no install recorded is named, and named again", async ($, on) => {
  const entry = "- skill git-tools:git-branch-sync (could not be read: ";
  stub(on, {});
  const first = reload(
    await $.session.compact({ trigger: "auto", messages: launched("git-tools:git-branch-sync") }),
  );
  expect(first).toContain(entry);
  const second = reload(await $.session.compact({ trigger: "auto", messages: [SUMMARY] }));
  expect(second).toContain(entry);
});

test("a file opened under an agents/ directory is not reloaded", async ($, on) => {
  const reads: string[] = [];
  const rule = `${ROOT}/docs/rules/a.md`;
  const agents = [
    `${ROOT}/plugins/sdlc/agents/issue-developer.md`,
    `${HOME}/.claude/agents/helper.md`,
    `${ROOT}/plugins/sdlc/skills/lib/agents/brief.md`,
    `${ROOT}/docs/rules/agents/notes.md`,
  ];
  host(on, {
    read: (path) => {
      reads.push(path);
      return path === rule ? "text" : undefined;
    },
  });
  const messages = [
    spawn("sdlc:issue-developer"),
    spawn("helper"),
    ...agents.map(read),
    read(rule),
  ];
  const text = reload(await $.session.compact({ trigger: "auto", messages }));
  expect(text).toContain(block(rule, "text"));
  expect(reads.filter((path) => path.includes("/agents/"))).toEqual([]);
  expect(text).not.toContain("/agents/");
  expect(text).not.toContain("issue-developer");
  expect(text).not.toContain("helper");
});

test("a skill of the hook's own plugin with no base directory resolves under the plugin root", async ($, on) => {
  const paths: string[] = [];
  host(on, {
    read: (path) => {
      paths.push(path);
      return "skill";
    },
    exists: () => false,
  });
  reload(await $.session.compact({ trigger: "auto", messages: launched("sdlc:git-review-pr") }));
  expect(paths.some((path) => path.endsWith("/sdlc/skills/git-review-pr/SKILL.md"))).toBe(true);
  expect(paths.some((path) => path.includes("installed_plugins.json"))).toBe(false);
});

test("a skill of another plugin resolves to its installed version", async ($, on) => {
  // The hook's own plugin root names the marketplace, so the first compaction reads it off the
  // path the hook reads for a skill of its own plugin.
  const reads: string[] = [];
  const files: Record<string, string> = {};
  host(on, {
    read: (path) => {
      reads.push(path);
      return files[path];
    },
    exists: () => false,
  });
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
  // The main conversation compacts first, so its uses are in its own state file.
  reload(await $.session.compact({ trigger: "auto", messages: [read(mainRule)] }));
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

/** The messages that invoke the readiness skill and read the two orchestrate opening files. */
const OPENING_MESSAGES = [
  ...launched("sdlc:orchestrate-readiness"),
  read(`${SKILLS}/orchestrate/lib/pre-flight.md`),
  read(`${SKILLS}/orchestrate/lib/plan.md`),
];
const RULE = read(`${ROOT}/docs/rules/a.md`);

/** Stubs a disk on which every file reads as its own path and no config tier exists. */
function openingHost(on) {
  host(on, { read: (path) => path, exists: () => false });
}

async function compactOpening($, on, messages): Promise<string> {
  openingHost(on);
  return reload(await $.session.compact({ trigger: "auto", messages }));
}

test("orchestrate's opening files are dropped once an Agent call follows its invocation", async ($, on) => {
  const text = await compactOpening($, on, [
    typed("sdlc:orchestrate"),
    ...OPENING_MESSAGES,
    spawn("sdlc:issue-developer"),
    RULE,
  ]);
  for (const file of OPENING) expect(text).not.toContain(file);
  expect(text).toContain("/docs/rules/a.md (appended below)");
});

test("an orchestrate invocation in a message's second command tag opens a run", async ($, on) => {
  const invocation = {
    role: "user",
    text: "<command-name>/other</command-name>\n<command-name>/sdlc:orchestrate</command-name>",
    toolUses: [],
  };
  const text = await compactOpening($, on, [
    invocation,
    ...OPENING_MESSAGES,
    spawn("sdlc:issue-developer"),
    RULE,
  ]);
  for (const file of OPENING) expect(text).not.toContain(file);
});

test("orchestrate's opening files are reloaded before an Agent call follows its invocation", async ($, on) => {
  const text = await compactOpening($, on, [
    ...skill("sdlc:orchestrate", `${SKILLS}/orchestrate`),
    ...OPENING_MESSAGES,
    RULE,
  ]);
  for (const file of OPENING) expect(text).toMatch(new RegExp(`/${file} \\(appended below\\)`));
});

test("an Agent call before the orchestrate invocation leaves its opening files live", async ($, on) => {
  const text = await compactOpening($, on, [
    spawn("sdlc:pr-monitor"),
    typed("sdlc:orchestrate"),
    ...OPENING_MESSAGES,
    RULE,
  ]);
  for (const file of OPENING) expect(text).toMatch(new RegExp(`/${file} \\(appended below\\)`));
});

test("a later orchestrate invocation makes its opening files live until its own Agent call", async ($, on) => {
  const live = await compactOpening($, on, [
    typed("sdlc:orchestrate"),
    ...OPENING_MESSAGES,
    spawn("sdlc:issue-developer"),
    ...launched("sdlc:orchestrate"),
    RULE,
  ]);
  for (const file of OPENING) expect(live).toMatch(new RegExp(`/${file} \\(appended below\\)`));
});

test("a later orchestrate invocation's own Agent call drops its opening files again", async ($, on) => {
  const text = await compactOpening($, on, [
    typed("sdlc:orchestrate"),
    ...OPENING_MESSAGES,
    spawn("sdlc:issue-developer"),
    ...launched("sdlc:orchestrate"),
    RULE,
    spawn("sdlc:issue-fixer"),
  ]);
  for (const file of OPENING) expect(text).not.toContain(file);
});

test("a run past its opening stays past it once a compaction summarized its invocation away", async ($, on) => {
  openingHost(on);
  const first = reload(
    await $.session.compact({
      trigger: "auto",
      messages: [
        typed("sdlc:orchestrate"),
        ...OPENING_MESSAGES,
        spawn("sdlc:issue-developer"),
        RULE,
      ],
    }),
  );
  for (const file of OPENING) expect(first).not.toContain(file);
  const second = reload(await $.session.compact({ trigger: "auto", messages: [SUMMARY, RULE] }));
  for (const file of OPENING) expect(second).not.toContain(file);
  expect(second).toContain("/docs/rules/a.md (appended below)");
});

test("an Agent call after an invocation an earlier compaction summarized away ends the opening", async ($, on) => {
  openingHost(on);
  const first = reload(
    await $.session.compact({
      trigger: "auto",
      messages: [typed("sdlc:orchestrate"), ...OPENING_MESSAGES, RULE],
    }),
  );
  for (const file of OPENING) expect(first).toMatch(new RegExp(`/${file} \\(appended below\\)`));
  const second = reload(
    await $.session.compact({
      trigger: "auto",
      messages: [SUMMARY, spawn("sdlc:issue-developer"), RULE],
    }),
  );
  for (const file of OPENING) expect(second).not.toContain(file);
  expect(second).toContain("/docs/rules/a.md (appended below)");
});

test("past the budget, the most recently used are appended and the rest listed", async ($, on) => {
  const [a, b, c] = ["a", "b", "c"].map((name) => `${ROOT}/docs/rules/${name}.md`);
  // Each file is half the budget, so the two most recent fill it exactly.
  const size = MIN_BUDGET * 2;
  stub(on, {
    [a]: "a".repeat(size),
    [b]: "b".repeat(size),
    [c]: "c".repeat(size),
    [`${ROOT}/.sdlc/repo-config.yml`]: `schema-version: 1\n${BUDGET_KEY}: ${MIN_BUDGET}\n`,
  });
  const text = reload(
    await $.session.compact({ trigger: "auto", messages: [read(a), read(b), read(c)] }),
  );
  expect(text).toContain(block(c, "c".repeat(size)));
  expect(text).toContain(block(b, "b".repeat(size)));
  expect(text).not.toContain("a".repeat(size));
  expect(text).toContain(`- ${a} (not appended: read it before acting on it)`);
  expect(text.indexOf(`- ${c} `)).toBeLessThan(text.indexOf(`- ${b} `));
  expect(text).toContain(`budget of ${MIN_BUDGET} tokens`);
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
    [`${HOME}/.config/sdlc/user-config.yml`]: `schema-version: 1\n${BUDGET_KEY}: 70005\n`,
    [`${ROOT}/.sdlc/user-config.yml`]: `schema-version: 1\n${BUDGET_KEY}: 70007 # mine\n`,
  });
  const text = reload(await $.session.compact({ trigger: "auto", messages: [read(rule)] }));
  expect(text).toContain("budget of 70007 tokens");
});

test("XDG_CONFIG_HOME locates the global tier", async ($, on) => {
  const rule = `${ROOT}/docs/rules/a.md`;
  stub(
    on,
    { [rule]: "rule", [`/xdg/sdlc/user-config.yml`]: `schema-version: 1\n${BUDGET_KEY}: 70009\n` },
    {},
    { XDG_CONFIG_HOME: "/xdg" },
  );
  const text = reload(await $.session.compact({ trigger: "auto", messages: [read(rule)] }));
  expect(text).toContain("budget of 70009 tokens");
});

for (const [name, config] of [
  ["zero", `schema-version: 1\n${BUDGET_KEY}: 0\n`],
  ["a signed zero", `schema-version: 1\n${BUDGET_KEY}: +0\n`],
  ["an integer just below the floor", `schema-version: 1\n${BUDGET_KEY}: ${MIN_BUDGET - 1}\n`],
  ["a small integer", `schema-version: 1\n${BUDGET_KEY}: 50000\n`],
  ["a signed integer", `schema-version: 1\n${BUDGET_KEY}: +70000\n`],
  ["an integer with leading zeros", `schema-version: 1\n${BUDGET_KEY}: 0070000\n`],
  ["a hex integer", `schema-version: 1\n${BUDGET_KEY}: 0x11170\n`],
  ["an integer with underscores", `schema-version: 1\n${BUDGET_KEY}: 70_000\n`],
  ["a quoted string", `schema-version: 1\n${BUDGET_KEY}: "70000"\n`],
  ["a float", `schema-version: 1\n${BUDGET_KEY}: 70000.5\n`],
  ["a flow mapping", `schema-version: 1\n{${BUDGET_KEY}: 70000}\n`],
  ["a value on the next line", `schema-version: 1\n${BUDGET_KEY}:\n  70000\n`],
  ["a quoted key", `schema-version: 1\n"${BUDGET_KEY}": 70000\n`],
  ["a sequence entry's key", `schema-version: 1\nitems:\n  - ${BUDGET_KEY}: 70000\n`],
  ["the key twice", `schema-version: 1\n${BUDGET_KEY}: 70000\n${BUDGET_KEY}: 80000\n`],
  ["no schema-version", `${BUDGET_KEY}: 70000\n`],
]) {
  test(`a tier holding ${name} falls back to the default and names the path`, async ($, on) => {
    const rule = `${ROOT}/docs/rules/a.md`;
    const tier = `${ROOT}/.sdlc/repo-config.yml`;
    stub(on, {
      [rule]: "rule",
      [tier]: config,
      [`${ROOT}/.sdlc/user-config.yml`]: `schema-version: 1\n${BUDGET_KEY}: 70003\n`,
    });
    const text = reload(await $.session.compact({ trigger: "auto", messages: [read(rule)] }));
    expect(text).toContain(`budget of ${DEFAULT_BUDGET} tokens`);
    expect(text).toContain(`- ${tier}: `);
    expect(text).toContain(block(rule, "rule"));
  });
}

test("a budget below the floor is named with the floor", async ($, on) => {
  const rule = `${ROOT}/docs/rules/a.md`;
  const tier = `${ROOT}/.sdlc/repo-config.yml`;
  stub(on, { [rule]: "rule", [tier]: `schema-version: 1\n${BUDGET_KEY}: 50000\n` });
  const text = reload(await $.session.compact({ trigger: "auto", messages: [read(rule)] }));
  expect(text).toContain(
    `- ${tier}: \`${BUDGET_KEY}\` is \`50000\`, not a plain decimal integer of at least ${MIN_BUDGET}`,
  );
});

for (const [name, config, budget] of [
  ["the floor itself", `schema-version: 1\n${BUDGET_KEY}: ${MIN_BUDGET}\n`, MIN_BUDGET],
  [
    "unlisted keys with quoted and dotted names",
    `schema-version: 1\n"odd key": x\nmerge.wait: skip\n'other': 2\n${BUDGET_KEY}: 70011\n`,
    70011,
  ],
  [
    "a line that is no key of its own",
    `schema-version: 1\nthis is not yaml\n${BUDGET_KEY}: 70013\n`,
    70013,
  ],
  [
    "a commented-out budget line",
    `schema-version: 1\n# ${BUDGET_KEY}: 0\n${BUDGET_KEY}: 70017\n`,
    70017,
  ],
  [
    "the key named inside another key's value",
    `schema-version: 1\ndescription: see ${BUDGET_KEY}: 5\n${BUDGET_KEY}: 70019\n`,
    70019,
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

test("a file used before an earlier compaction is still reloaded at a later one", async ($, on) => {
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
  // The earlier reload message is left out of the transcript, so nothing can be read off it.
  const second = reload(
    await $.session.compact({ trigger: "auto", messages: [SUMMARY, read(later)] }),
  );
  expect(second).toContain(block(rule, "rule"));
  expect(second).toContain(block(later, "later"));
  expect(second).toContain(unresolved);
  expect(second.indexOf(`- ${later} `)).toBeLessThan(second.indexOf(`- ${rule} `));
  const third = reload(await $.session.compact({ trigger: "auto", messages: [SUMMARY] }));
  expect(third).toContain(block(rule, "rule"));
  expect(third).toContain(block(later, "later"));
});

test("an earlier reload message's text is never read as a use", async ($, on) => {
  const rule = `${ROOT}/docs/rules/a.md`;
  const later = `${ROOT}/docs/rules/b.md`;
  stub(on, { [rule]: "rule", [later]: "later" });
  const earlier = {
    role: "user",
    text: `${MARKER}\n\nFiles, most recently used first:\n- ${rule} (appended below)\n\n${block(rule, "rule")}`,
    toolUses: [],
  };
  const text = reload(
    await $.session.compact({ trigger: "auto", messages: [SUMMARY, earlier, read(later)] }),
  );
  expect(text).toContain(block(later, "later"));
  expect(text).not.toContain(rule);
});

test("uses are recorded under XDG_STATE_HOME, by session and by loop", async ($, on) => {
  const rule = `${ROOT}/docs/rules/a.md`;
  const written = stub(on, { [rule]: "rule" }, {}, { XDG_STATE_HOME: "/xdg-state" });
  reload(await $.session.compact({ trigger: "auto", messages: [read(rule)] }));
  reload(await $.session.compact({ trigger: "auto", agentId: "a1", messages: [read(rule)] }));
  const dir = `/xdg-state/sdlc/reload-after-compact/${SESSION}`;
  expect(Object.keys(written).sort()).toEqual([`${dir}/agent-a1.json`, `${dir}/main.json`]);
});

test("a state file that cannot be read is named with its error, and the compaction completes", async ($, on) => {
  const rule = `${ROOT}/docs/rules/a.md`;
  stub(on, { [rule]: "rule" }, { [`${STATE}/main.json`]: "EACCES: permission denied" });
  const text = reload(await $.session.compact({ trigger: "auto", messages: [read(rule)] }));
  expect(text).toContain(`- ${STATE}/main.json: `);
  expect(text).toContain("EACCES: permission denied");
  expect(text).toContain(block(rule, "rule"));
});

test("a state file that holds no state is named with its error, and the compaction completes", async ($, on) => {
  const rule = `${ROOT}/docs/rules/a.md`;
  stub(on, { [rule]: "rule", [`${STATE}/main.json`]: "not json" });
  const text = reload(await $.session.compact({ trigger: "auto", messages: [read(rule)] }));
  expect(text).toContain(`- ${STATE}/main.json: not JSON`);
  expect(text).toContain(block(rule, "rule"));
});

test("a state file whose use has a field of the wrong type is named, and rewritten", async ($, on) => {
  const rule = `${ROOT}/docs/rules/a.md`;
  const state = `${STATE}/main.json`;
  const written = stub(on, {
    [rule]: "rule",
    [state]: JSON.stringify({ uses: [{ skill: "x", path: 5 }], orchestrate: "none" }),
  });
  const text = reload(await $.session.compact({ trigger: "auto", messages: [read(rule)] }));
  expect(text).toContain(`- ${state}: not a state file this hook wrote`);
  expect(text).toContain(block(rule, "rule"));
  expect(JSON.parse(written[state])).toEqual({ uses: [{ path: rule }], orchestrate: "none" });
});

test("a state file that cannot be written is named with its error, and the compaction completes", async ($, on) => {
  const rule = `${ROOT}/docs/rules/a.md`;
  host(on, {
    read: (path) => (path === rule ? "rule" : undefined),
    refuseWrite: "EROFS: read-only file system",
  });
  const text = reload(await $.session.compact({ trigger: "auto", messages: [read(rule)] }));
  expect(text).toContain(`- ${STATE}/main.json: `);
  expect(text).toContain("EROFS: read-only file system");
  expect(text).toContain(block(rule, "rule"));
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

test("a reload already in the result is replaced, and its text is not read", async ($, on) => {
  const rule = `${ROOT}/docs/rules/a.md`;
  const later = `${ROOT}/docs/rules/b.md`;
  const stale = {
    role: "user",
    text: `${MARKER}\n\nFiles, most recently used first:\n- ${rule} (appended below)`,
    toolUses: [],
  };
  host(on, {
    read: (path) => ({ [rule]: "rule", [later]: "later" })[path],
    compacted: { messages: [SUMMARY, stale] },
  });
  const text = reload(await $.session.compact({ trigger: "auto", messages: [read(later)] }));
  expect(text).toContain(block(later, "later"));
  expect(text).not.toContain(rule);
});

test("a reload in the result is dropped when there is nothing fresh to reload", async ($, on) => {
  const stale = { role: "user", text: `${MARKER}\n\nNothing named.`, toolUses: [] };
  host(on, { compacted: { messages: [SUMMARY, stale] } });
  const result = await $.session.compact({
    trigger: "auto",
    messages: [read(`${ROOT}/src/main.go`)],
  });
  expect(result.messages).toEqual([SUMMARY]);
});

test("a reload in the result naming opening files is dropped once the run is past its opening", async ($, on) => {
  const preFlight = `${SKILLS}/orchestrate/lib/pre-flight.md`;
  const stale = {
    role: "user",
    text: `${MARKER}\n\nFiles, most recently used first:\n- ${preFlight} (appended below)`,
    toolUses: [],
  };
  host(on, {
    read: (path) => path,
    exists: () => false,
    compacted: { messages: [SUMMARY, stale] },
  });
  const text = reload(
    await $.session.compact({
      trigger: "auto",
      messages: [typed("sdlc:orchestrate"), read(preFlight), spawn("sdlc:issue-developer")],
    }),
  );
  expect(text).toContain("/sdlc/skills/orchestrate/SKILL.md (appended below)");
  expect(text).not.toContain("pre-flight.md");
});
