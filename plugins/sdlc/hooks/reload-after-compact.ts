// After a compaction, appends to the compacted conversation the full text of the skills and rule
// files the compacting loop loaded before it, so the loop works from those files rather than from
// the summary's truncated account of them.

// The key and its default must match the key table in `skills/lib/sdlc-config.md`, and
// `SCHEMA_PIN` the pin its "Reading" section states, since the orchestrator reads them there.
/** The reload budget when no config tier sets one, in tokens counted as characters divided by 4. */
export const DEFAULT_BUDGET = 100000;
/** The sdlc config key whose value replaces `DEFAULT_BUDGET`. */
export const BUDGET_KEY = "reload-after-compact-token-budget";
/** The opening of every reload message, by which a later compaction recognises one. */
export const MARKER = "<reload-after-compact>";

const SCHEMA_PIN = 1;
const MANIFEST_HEADING = "Files, most recently used first:";
const APPENDED = "appended below";
const NOT_APPENDED = "not appended: read it before acting on it";
const UNREADABLE = "could not be read";
const SKILL_BASE = /Base directory for this skill: (.+)/g;
const COMMAND_NAME = /<command-name>\/?([^<\s]+)<\/command-name>/;
const RULE_DIRS = ["/rules/", "/skills/", "/agents/"];
const ORCHESTRATE = "sdlc:orchestrate";
// The files that serve only the opening of an orchestrate run, which spawns no agent until
// pre-flight, the readiness gate and the plan confirmation are done.
const OPENING_FILES = [
  "/skills/orchestrate-readiness/SKILL.md",
  "/skills/orchestrate/lib/pre-flight.md",
  "/skills/orchestrate/lib/plan.md",
];
const TIER_KEY = new RegExp(`^(["']?)(schema-version|${BUDGET_KEY})\\1:(?:\\s+(.*))?$`);

type ToolUse = { tool: string; input: Record<string, unknown>; text?: string };
type Message = { role: "user" | "assistant"; text: string; toolUses?: readonly ToolUse[] };

type Mods = {
  plugin: { name: string; root: string };
  env: { get: (name: string) => Promise<string | undefined> };
  session: { root: () => Promise<string> };
  fs: {
    read: (path: string) => Promise<string>;
    exists: (path: string) => Promise<boolean>;
  };
};

type Compacted = { messages?: readonly Message[]; skip?: string };
type CompactEvent = { trigger: string; messages: readonly Message[] };

/** One file to reload: `label` is its absolute path, or a description when no path resolved. */
type Item = { label: string; seq: number; error?: string };

/**
 * What the walk over a transcript finds, each keyed to the position of its last use: `skills`
 * holds the skills known only by name, which `skillItem` resolves to a file.
 */
type Uses = {
  paths: Map<string, number>;
  skills: Map<string, number>;
};

/**
 * The skills a transcript loaded: `calls` holds the base directory each `Skill` call resolved to,
 * `invoked` the base directories no call claimed, by the index of the message naming them, and
 * `commands` the skill name of each slash command whose message names no base directory, by the
 * index of that message.
 */
type Skills = {
  calls: Map<ToolUse, string>;
  invoked: Map<number, string[]>;
  commands: Map<number, string>;
};

/** One line of an earlier reload message's manifest: a file's path, or an unresolved skill name. */
type Entry = { path: string } | { skill: string };

/** One install of a plugin, as `installed_plugins.json` records it. */
type Install = { projectPath?: unknown; version?: unknown } | null;

type Next = (e: CompactEvent) => Promise<Compacted>;
type On = (event: string, hook: unknown) => { catch: (handler: unknown) => void };

/**
 * Registers the `session.compact` hook, which lets the compaction run and then appends one reload
 * message after its messages, replacing any reload message already among them. With nothing to
 * reload it returns the compaction as `next` resolved it.
 */
export function register(on: On): void {
  // The `.catch` handler makes a throw or a timeout leave the compaction as `next` resolved it,
  // with no reload.
  on("session.compact", async ($: Mods, e: CompactEvent, next: Next) => {
    const result = await next(e);
    if (result.skip !== undefined || result.messages === undefined) return result;
    // A result can already carry a reload message, as one core reuses from a precompute does. The
    // fresh one replaces it, and counts every file its manifest names as used before the
    // transcript's own uses, so a file only the old one named is not lost.
    const stale = result.messages.filter(isReload);
    const text = await reloadText($, [...stale, ...e.messages]);
    if (text === "") return result;
    const kept = result.messages.filter((message) => !isReload(message));
    return { ...result, messages: [...kept, { role: "user", text, toolUses: [] }] };
  }).catch(($: Mods, e: CompactEvent, next: Next) => next(e));
}

/**
 * Builds the reload message for a transcript about to be compacted, or `''` when the transcript
 * loaded nothing to reload. A file or config tier that cannot be read is named in the text with
 * its error rather than rejecting.
 */
async function reloadText($: Mods, messages: readonly Message[]): Promise<string> {
  const home = (await $.env.get("HOME")) ?? "";
  const skills = resolveSkills(messages);
  const uses = collectUses(messages, skills);
  const items: Item[] = [];
  for (const [path, seq] of uses.paths) items.push({ label: path, seq });
  for (const [name, seq] of uses.skills) {
    const item = await skillItem($, name, seq, home);
    if (item !== undefined) items.push(item);
  }
  const isOpened = isOrchestrateOpened(messages);
  const kept = mergeByLabel(items).filter(
    (item) => !isReinjected(item.label, home) && !(isOpened && isOpeningFile(item.label)),
  );
  if (kept.length === 0) return "";
  kept.sort((a, b) => b.seq - a.seq);

  const { budget, notes } = await readBudget($, home);
  const manifest: string[] = [];
  const blocks: string[] = [];
  let spent = 0;
  let isOver = false;
  for (const item of kept) {
    if (item.error !== undefined) {
      manifest.push(`- ${item.label} (${UNREADABLE}: ${item.error})`);
      continue;
    }
    if (isOver) {
      manifest.push(`- ${item.label} (${NOT_APPENDED})`);
      continue;
    }
    let content: string;
    try {
      content = await $.fs.read(item.label);
    } catch (err) {
      manifest.push(`- ${item.label} (${UNREADABLE}: ${errorText(err)})`);
      continue;
    }
    const tokens = Math.ceil(content.length / 4);
    if (spent + tokens > budget) {
      isOver = true;
      manifest.push(`- ${item.label} (${NOT_APPENDED})`);
      continue;
    }
    spent += tokens;
    manifest.push(`- ${item.label} (${APPENDED})`);
    blocks.push(`<file path="${item.label}">\n${content}\n</file>`);
  }

  const parts = [
    MARKER,
    "The conversation was just compacted, and its summary truncates or omits the skills and rule " +
      "files the conversation loaded before it. Their full text follows; act on it rather than on " +
      "the summary's account of them. A file listed as not appended is past the reload budget of " +
      `${budget} tokens: read it with the Read tool before acting on it.`,
    [MANIFEST_HEADING, ...manifest].join("\n"),
  ];
  if (notes.length > 0) {
    parts.push(
      [
        `Config: the budget is the default, ${DEFAULT_BUDGET} tokens, because a tier of \`${BUDGET_KEY}\` failed:`,
        ...notes.map((note) => `- ${note}`),
      ].join("\n"),
    );
  }
  parts.push(...blocks, "</reload-after-compact>");
  return parts.join("\n\n");
}

/**
 * Walks the transcript oldest first and records the last position at which each skill and rule
 * file was used. A skill counts by its file when the transcript names its base directory, and by
 * its name otherwise. A reload message from an earlier compaction counts as a use of every file
 * and unresolved skill its manifest names, so a second compaction reloads them again.
 */
function collectUses(messages: readonly Message[], skills: Skills): Uses {
  const paths = new Map<string, number>();
  const names = new Map<string, number>();
  let seq = 0;
  messages.forEach((message, index) => {
    if (isReload(message)) {
      for (const entry of manifestEntries(message.text).reverse()) {
        if ("path" in entry) paths.set(entry.path, seq++);
        else names.set(entry.skill, seq++);
      }
    }
    for (const base of skills.invoked.get(index) ?? []) paths.set(`${base}/SKILL.md`, seq++);
    const command = skills.commands.get(index);
    if (command !== undefined) names.set(command, seq++);
    for (const use of message.toolUses ?? []) {
      if (use.tool === "Skill") {
        const base = skills.calls.get(use);
        const skill = use.input.skill;
        if (base !== undefined) paths.set(`${base}/SKILL.md`, seq++);
        else if (typeof skill === "string" && skill !== "") names.set(skill, seq++);
      } else if (use.tool === "Read") {
        const path = use.input.file_path;
        if (typeof path === "string" && isRuleFile(path)) paths.set(path, seq++);
      }
    }
  });
  return { paths, skills: names };
}

/**
 * True when an `Agent` call follows the transcript's most recent `/sdlc:orchestrate` invocation,
 * as a `Skill` call or a slash command. That run's opening is then over, so its opening files are
 * not reloaded. A reload message from an earlier compaction is no invocation.
 */
function isOrchestrateOpened(messages: readonly Message[]): boolean {
  let isInvoked = false;
  let isOpened = false;
  for (const message of messages) {
    if (message.role === "user" && !isReload(message)) {
      if (COMMAND_NAME.exec(message.text)?.[1] === ORCHESTRATE)
        [isInvoked, isOpened] = [true, false];
    }
    for (const use of message.toolUses ?? []) {
      if (use.tool === "Skill" && use.input.skill === ORCHESTRATE) {
        [isInvoked, isOpened] = [true, false];
      } else if (use.tool === "Agent" && isInvoked) {
        isOpened = true;
      }
    }
  }
  return isOpened;
}

/** True for a path ending in one of `OPENING_FILES`, under whichever directory holds the plugin. */
function isOpeningFile(path: string): boolean {
  return OPENING_FILES.some((file) => path.endsWith(file));
}

/** True for a Markdown file under a `rules/`, `skills/` or `agents/` directory. */
function isRuleFile(path: string): boolean {
  return path.endsWith(".md") && RULE_DIRS.some((dir) => path.includes(dir));
}

/** True for a file the harness itself re-injects after a compaction. */
function isReinjected(path: string, home: string): boolean {
  return (
    baseName(path) === "CLAUDE.md" || (home !== "" && path.startsWith(`${home}/.claude/rules/`))
  );
}

/**
 * Resolves every `Skill` call to the base directory its expansion names, when the transcript
 * carries the expansion. A call whose own result names one takes it. The other calls of one
 * message take, in call order, the base directories the messages up to the next assistant message
 * name. A base directory no call takes is a skill invoked as a slash command.
 *
 * The harness keeps a skill's expansion out of the messages a `session.compact` hook receives,
 * for a `Skill` call and a slash command alike: the call's result reads `Launching skill: <name>`
 * and the slash command's message holds only its `<command-message>`, `<command-name>` and
 * `<command-args>` tags. So a slash command whose message names no base directory is recorded by
 * the name in its `<command-name>` tag.
 */
function resolveSkills(messages: readonly Message[]): Skills {
  const calls = new Map<ToolUse, string>();
  const invoked = new Map<number, string[]>();
  const commands = new Map<number, string>();
  messages.forEach((message, index) => {
    if (message.role === "assistant" || isReload(message)) return;
    const bases = baseDirs(message.text);
    invoked.set(index, bases);
    const command = COMMAND_NAME.exec(message.text)?.[1];
    if (bases.length === 0 && command !== undefined) commands.set(index, command);
  });
  messages.forEach((message, index) => {
    const pending: ToolUse[] = [];
    for (const use of message.toolUses ?? []) {
      if (use.tool !== "Skill") continue;
      const own = baseDirs(use.text ?? "")[0];
      if (own !== undefined) calls.set(use, own);
      else pending.push(use);
    }
    for (let i = index + 1; i < messages.length && messages[i].role !== "assistant"; i++) {
      const bases = invoked.get(i) ?? [];
      while (pending.length > 0 && bases.length > 0) calls.set(pending.shift()!, bases.shift()!);
    }
  });
  return { calls, invoked, commands };
}

/** Every skill base directory a text names, in order, without a trailing slash. */
function baseDirs(text: string): string[] {
  return [...text.matchAll(SKILL_BASE)].map((match) => match[1].trim().replace(/\/+$/, ""));
}

/**
 * Resolves a skill known only by name to its `SKILL.md`. A plugin skill `<plugin>:<name>`
 * resolves to `skills/<name>/SKILL.md` in the plugin's directory, as `pluginDir` finds it. A
 * name with no plugin prefix resolves under the project's `.claude/skills/`, then under
 * `~/.claude/skills/`, and with a file in neither is a built-in command and resolves to nothing.
 * A plugin whose directory cannot be found resolves to an item carrying the error.
 */
async function skillItem(
  $: Mods,
  name: string,
  seq: number,
  home: string,
): Promise<Item | undefined> {
  const colon = name.indexOf(":");
  try {
    if (colon >= 0) {
      const dir = await pluginDir($, name.slice(0, colon), home);
      return { label: `${dir}/skills/${name.slice(colon + 1)}/SKILL.md`, seq };
    }
    const project = `${await $.session.root()}/.claude/skills/${name}/SKILL.md`;
    if (await $.fs.exists(project)) return { label: project, seq };
    const user = `${home}/.claude/skills/${name}/SKILL.md`;
    return home !== "" && (await $.fs.exists(user)) ? { label: user, seq } : undefined;
  } catch (err) {
    return { label: `skill ${name}`, seq, error: errorText(err) };
  }
}

/**
 * A plugin's directory: the hook's own plugin root for its own plugin, else the plugin's install
 * in the cache. Rejects as `cachedPluginDir` does.
 */
async function pluginDir($: Mods, plugin: string, home: string): Promise<string> {
  return plugin === $.plugin.name ? $.plugin.root : await cachedPluginDir($, plugin, home);
}

/**
 * A plugin's directory in the cache of the marketplace this hook module was installed from:
 * `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>`, at the version
 * `~/.claude/plugins/installed_plugins.json` records for the install of `<plugin>@<marketplace>`
 * whose `projectPath` is the session's root, or else for the install with no `projectPath`.
 * Rejects when that file cannot be read or parsed, or records no such install.
 */
async function cachedPluginDir($: Mods, plugin: string, home: string): Promise<string> {
  const marketplace = baseName(dirName(dirName($.plugin.root)));
  const id = `${plugin}@${marketplace}`;
  const registry = `${home}/.claude/plugins/installed_plugins.json`;
  const text = await $.fs.read(registry);
  let installs: unknown;
  try {
    installs = JSON.parse(text)?.plugins?.[id];
  } catch (err) {
    throw new Error(`${registry}: ${errorText(err)}`);
  }
  const list = (Array.isArray(installs) ? installs : []) as Install[];
  const root = await $.session.root();
  const install =
    list.find((entry) => entry?.projectPath === root) ??
    list.find((entry) => entry?.projectPath === undefined || entry?.projectPath === null);
  const version = install?.version;
  if (typeof version !== "string" || version === "") {
    throw new Error(`${registry} records no installed version of ${id}`);
  }
  return `${home}/.claude/plugins/cache/${marketplace}/${plugin}/${version}`;
}

/**
 * Resolves `reload-after-compact-token-budget` over the sdlc config tiers, highest tier
 * winning. A tier that cannot be read, or that `parseTier` refuses, makes the budget the default
 * and adds a note naming the path and the error.
 */
async function readBudget($: Mods, home: string): Promise<{ budget: number; notes: string[] }> {
  const xdg = await $.env.get("XDG_CONFIG_HOME");
  const configHome = xdg !== undefined && xdg !== "" ? xdg : `${home}/.config`;
  const root = await $.session.root();
  const tiers = [
    `${configHome}/sdlc/user-config.yml`,
    `${root}/.sdlc/repo-config.yml`,
    `${root}/.sdlc/user-config.yml`,
  ];
  let budget = DEFAULT_BUDGET;
  const notes: string[] = [];
  for (const path of tiers) {
    let text: string;
    try {
      if (!(await $.fs.exists(path))) continue;
      text = await $.fs.read(path);
    } catch (err) {
      notes.push(`${path}: ${errorText(err)}`);
      continue;
    }
    const tier = parseTier(text);
    if (tier.error !== undefined) notes.push(`${path}: ${tier.error}`);
    else if (tier.value !== undefined) budget = tier.value;
  }
  return { budget: notes.length > 0 ? DEFAULT_BUDGET : budget, notes };
}

/**
 * Reads `schema-version` and the budget key off their own top-level lines and validates them, as
 * `skills/lib/sdlc-config.md` → "Reading" states. Every other line is ignored, so the rest of the
 * file's YAML is left to the orchestrator.
 */
function parseTier(text: string): { value?: number; error?: string } {
  let schema: string | undefined;
  let value: string | undefined;
  for (const raw of text.split("\n")) {
    const match = TIER_KEY.exec(raw.replace(/\r$/, ""));
    if (match === null) continue;
    const scalar = (match[3] ?? "").replace(/\s+#.*$/, "").trim();
    if (match[2] === "schema-version") schema = scalar;
    else value = scalar;
  }
  if (schema === undefined) return { error: "`schema-version` is absent" };
  if (!/^\d+$/.test(schema))
    return { error: `\`schema-version\` is \`${schema}\`, not an integer` };
  if (Number(schema) < SCHEMA_PIN) {
    return { error: `\`schema-version\` is ${schema}, lower than the pin ${SCHEMA_PIN}` };
  }
  if (value === undefined) return {};
  if (!/^\+?\d+$/.test(value) || Number(value) < 1)
    return { error: `\`${BUDGET_KEY}\` is \`${value}\`, not a positive integer` };
  return { value: Number(value) };
}

/** True for a reload message this hook appended at an earlier compaction. */
function isReload(message: Message): boolean {
  return message.role === "user" && message.text.startsWith(MARKER);
}

/** The paths and unresolved skill names an earlier reload message's manifest names, in its order. */
function manifestEntries(text: string): Entry[] {
  const lines = text.split("\n");
  const start = lines.indexOf(MANIFEST_HEADING);
  if (start < 0) return [];
  const entries: Entry[] = [];
  const entry = new RegExp(
    `^- (?:(/.+?)|skill (\\S+)) \\((?:${APPENDED}|${NOT_APPENDED}|${UNREADABLE})`,
  );
  for (const line of lines.slice(start + 1)) {
    if (!line.startsWith("- ")) break;
    const match = entry.exec(line);
    if (match === null) continue;
    if (match[1] !== undefined) entries.push({ path: match[1] });
    else entries.push({ skill: match[2] });
  }
  return entries;
}

/** Keeps one item per label, at its most recent use. */
function mergeByLabel(items: Item[]): Item[] {
  const byLabel = new Map<string, Item>();
  for (const item of items) {
    const seen = byLabel.get(item.label);
    if (seen === undefined || item.seq > seen.seq) byLabel.set(item.label, item);
  }
  return [...byLabel.values()];
}

function errorText(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function baseName(path: string): string {
  return path.slice(path.lastIndexOf("/") + 1);
}

function dirName(path: string): string {
  return path.slice(0, Math.max(path.lastIndexOf("/"), 0));
}
