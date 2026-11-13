// After a compaction, appends to the compacted conversation the full text of the skills and rule
// files the compacting loop loaded before it, so the loop works from those files rather than from
// the summary's truncated account of them. A reload message the compacted conversation already
// holds is removed, so it holds at most the one this compaction appends.

// The key, its default and its floor must match the key table in `skills/lib/sdlc-config.md`,
// and `SCHEMA_PIN` the pin its "Reading" section states, since the orchestrator reads them there.
/** The reload budget when no config tier sets one, in tokens counted as characters divided by 4. */
export const DEFAULT_BUDGET = 100000;
/**
 * The smallest budget a config tier may set: an orchestrate run's whole working set past its
 * opening, about 42k tokens, with headroom for the files the run's own work reads.
 */
export const MIN_BUDGET = 64000;
/** The sdlc config key whose value replaces `DEFAULT_BUDGET`. */
export const BUDGET_KEY = "reload-after-compact-token-budget";
/** The opening of every reload message, by which the hook tells one from any other message. */
export const MARKER = "<reload-after-compact>";

const SCHEMA_PIN = 1;
const APPENDED = "appended below";
const NOT_APPENDED = "not appended: read it before acting on it";
const UNREADABLE = "could not be read";
const SKILL_BASE = /Base directory for this skill: (.+)/g;
const COMMAND_NAME = /<command-name>\/?([^<\s]+)<\/command-name>/g;
const RULE_DIRS = ["/rules/", "/skills/"];
const AGENTS_DIR = "/agents/";
const ORCHESTRATE = "sdlc:orchestrate";
// The files that serve only the opening of an orchestrate run, which spawns no agent until
// pre-flight, the readiness gate and the plan confirmation are done.
const OPENING_FILES = [
  "/skills/orchestrate-readiness/SKILL.md",
  "/skills/orchestrate/lib/pre-flight.md",
  "/skills/orchestrate/lib/plan.md",
];
const SCHEMA_LINE = /^(["']?)schema-version\1:(?:\s+(.*))?$/;
// The one valid budget line. `parseTier` holds its integer to `MIN_BUDGET`.
const BUDGET_LINE = new RegExp(`^${BUDGET_KEY}: ([0-9]+)$`);

/** One tool call in a transcript message: `text` is the text of the call's result. */
type ToolUse = { tool: string; input: Record<string, unknown>; text?: string };
type Message = { role: "user" | "assistant"; text: string; toolUses?: readonly ToolUse[] };

/**
 * The host modules the hook reaches through `$`: `plugin.root` is the directory of the hook's own
 * plugin install, and `session.root` the project's root.
 */
type Mods = {
  plugin: { name: string; root: string };
  env: { get: (name: string) => Promise<string | undefined> };
  session: { root: () => Promise<string>; id: () => Promise<string> };
  fs: {
    read: (path: string) => Promise<string>;
    write: (path: string, text: string) => Promise<void>;
    exists: (path: string) => Promise<boolean>;
  };
  ui: { log: (text: string) => Promise<void> };
};

/** What a compaction resolves to: its messages, or in `skip` the reason it did not compact. */
type Compacted = { messages?: readonly Message[]; skip?: string };
/** One loop's compaction: `agentId` is set for a subagent's loop and absent for the main one. */
type CompactEvent = { trigger: string; agentId?: string; messages: readonly Message[] };

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
 * `commands` the skill names of the slash commands no base directory was paired with, by the
 * index of the message naming them.
 */
type Skills = {
  calls: Map<ToolUse, string>;
  invoked: Map<number, string[]>;
  commands: Map<number, string[]>;
};

/** One use the state file records: a file's absolute path, or a skill known only by name. */
type Use = { path: string } | { skill: string };

/**
 * Where the loop's most recent `/sdlc:orchestrate` run stands: never invoked, invoked with no
 * `Agent` call since, or past its opening.
 */
type Orchestrate = "none" | "opening" | "opened";

/**
 * What the state file carries from one compaction of a loop to the next: every use, oldest
 * first, and where the loop's orchestrate run stands.
 */
type State = { uses: Use[]; orchestrate: Orchestrate };

/** One install of a plugin, as `installed_plugins.json` records it. */
type Install = { projectPath?: unknown; version?: unknown } | null;

type Next = (e: CompactEvent) => Promise<Compacted>;
type On = (event: string, hook: unknown) => { catch: (handler: unknown) => void };

const NO_STATE: State = { uses: [], orchestrate: "none" };

/**
 * Registers the `session.compact` hook, which lets the compaction run, removes every reload
 * message from its messages, and then appends one fresh reload message after them. When the loop
 * loaded nothing to reload and its state file raised no error, or a config tier failed, it
 * appends none, so the compaction ends with no reload message at all.
 */
export function register(on: On): void {
  // The `.catch` handler makes a throw or a timeout leave the compaction as `next` resolved it,
  // with no reload.
  on("session.compact", async ($: Mods, e: CompactEvent, next: Next) => {
    const result = await next(e);
    if (result.skip !== undefined || result.messages === undefined) return result;
    // A result can already carry a reload message, as one core reuses from a precompute does.
    // Its text is never read: the files it named are the uses this hook recorded in the state
    // file when it wrote that message.
    const kept = result.messages.filter((message) => !isReload(message));
    const text = await reloadText($, e);
    if (text === "") return { ...result, messages: kept };
    return { ...result, messages: [...kept, { role: "user", text, toolUses: [] }] };
  }).catch(($: Mods, e: CompactEvent, next: Next) => next(e));
}

/**
 * Records the compacting loop's uses in its state file and builds the reload message, or `''`
 * when the loop loaded nothing to reload and the state file raised no error. A file or state file
 * that cannot be read or written is named in the text with its error rather than rejecting. A
 * config tier that cannot be read or that `parseTier` refuses makes it `''` too, with one
 * `$.ui.log` line to the human naming each such tier's path and error, and nothing about it in
 * the text.
 */
async function reloadText($: Mods, e: CompactEvent): Promise<string> {
  const home = (await $.env.get("HOME")) ?? "";
  const stateNotes: string[] = [];
  let statePath: string | undefined;
  let recorded = NO_STATE;
  try {
    statePath = await stateFile($, home, e.agentId);
    recorded = await readState($, statePath);
  } catch (err) {
    stateNotes.push(`${statePath ?? "the state file"}: ${errorText(err)}`);
  }
  const skills = resolveSkills(e.messages);
  const uses = collectUses(e.messages, skills, recorded.uses);
  const orchestrate = orchestrateState(e.messages, recorded.orchestrate);
  if (statePath !== undefined) {
    // `$.fs.write` creates the file's missing directories, and `$.fs` has no call of its own that
    // creates one, so a loop's first write lands with no directory made beforehand.
    try {
      await $.fs.write(statePath, JSON.stringify({ uses: orderedUses(uses), orchestrate }));
    } catch (err) {
      stateNotes.push(`${statePath}: ${errorText(err)}`);
    }
  }

  // The uses are recorded above even when a tier failed, so the compaction after the tier is
  // repaired still reloads them.
  const { budget, errors } = await readBudget($, home);
  if (errors.length > 0) {
    await $.ui.log(
      `reload-after-compact reloaded nothing, because a config tier failed: ${errors.join("; ")}`,
    );
    return "";
  }

  const items: Item[] = [];
  for (const [path, seq] of uses.paths) items.push({ label: path, seq });
  for (const [name, seq] of uses.skills) {
    const item = await skillItem($, name, seq, home);
    if (item !== undefined) items.push(item);
  }
  const isOpened = orchestrate === "opened";
  const kept = mergeByLabel(items).filter(
    (item) => !isReinjected(item.label, home) && !(isOpened && isOpeningFile(item.label)),
  );
  if (kept.length === 0 && stateNotes.length === 0) return "";
  kept.sort((a, b) => b.seq - a.seq);

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
  if (manifest.length === 0) manifest.push("(none)");

  const parts = [
    MARKER,
    "The conversation was just compacted, and its summary truncates or omits the skills and rule " +
      "files the conversation loaded before it. Their full text follows; act on it rather than on " +
      "the summary's account of them. A file listed as not appended is past the reload budget of " +
      `${budget} tokens: read it with the Read tool before acting on it.`,
    ["Files, most recently used first:", ...manifest].join("\n"),
  ];
  if (stateNotes.length > 0) {
    parts.push(
      [
        "State: the files used before an earlier compaction may be missing from this reload or a " +
          "later one, because the state file that records them failed:",
        ...stateNotes.map((note) => `- ${note}`),
      ].join("\n"),
    );
  }
  parts.push(...blocks, "</reload-after-compact>");
  return parts.join("\n\n");
}

/**
 * The compacting loop's state file:
 * `${XDG_STATE_HOME:-$HOME/.local/state}/sdlc/reload-after-compact/<session>/<loop>.json`, with
 * `<loop>` `main` for the main conversation and `agent-<agentId>` for a subagent's own loop.
 * Rejects when the session id cannot be read, or neither `XDG_STATE_HOME` nor `HOME` is set.
 */
async function stateFile($: Mods, home: string, agentId: string | undefined): Promise<string> {
  const xdg = await $.env.get("XDG_STATE_HOME");
  if ((xdg === undefined || xdg === "") && home === "") {
    throw new Error("neither XDG_STATE_HOME nor HOME is set");
  }
  const stateHome = xdg !== undefined && xdg !== "" ? xdg : `${home}/.local/state`;
  const session = encodeURIComponent(await $.session.id());
  const loop = agentId === undefined ? "main" : `agent-${encodeURIComponent(agentId)}`;
  return `${stateHome}/sdlc/reload-after-compact/${session}/${loop}.json`;
}

/**
 * The state a loop's earlier compactions recorded, or `NO_STATE` when the file does not exist.
 * Rejects when it cannot be read, or does not hold a state this hook wrote.
 */
async function readState($: Mods, path: string): Promise<State> {
  if (!(await $.fs.exists(path))) return NO_STATE;
  const text = await $.fs.read(path);
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch (err) {
    throw new Error(`not JSON: ${errorText(err)}`);
  }
  const state = data as { uses?: unknown; orchestrate?: unknown } | null;
  const uses = state?.uses;
  const orchestrate = state?.orchestrate;
  if (
    !Array.isArray(uses) ||
    !uses.every(isUse) ||
    (orchestrate !== "none" && orchestrate !== "opening" && orchestrate !== "opened")
  ) {
    throw new Error("not a state file this hook wrote");
  }
  return { uses, orchestrate };
}

/**
 * True for a use as `orderedUses` writes it: an object whose one field is a string `path` or a
 * string `skill`.
 */
function isUse(use: unknown): use is Use {
  if (typeof use !== "object" || use === null || Array.isArray(use)) return false;
  const fields = Object.entries(use);
  return (
    fields.length === 1 &&
    (fields[0][0] === "path" || fields[0][0] === "skill") &&
    typeof fields[0][1] === "string"
  );
}

/** Every use, oldest first, as the state file records them. */
function orderedUses(uses: Uses): Use[] {
  const all: { use: Use; seq: number }[] = [];
  for (const [path, seq] of uses.paths) all.push({ use: { path }, seq });
  for (const [skill, seq] of uses.skills) all.push({ use: { skill }, seq });
  return all.sort((a, b) => a.seq - b.seq).map((entry) => entry.use);
}

/**
 * Walks the recorded uses and then the transcript, oldest first, and records the last position at
 * which each skill and rule file was used, so a use the transcript repeats moves past every
 * recorded one. A skill counts by its file when the transcript names its base directory, and by
 * its name otherwise.
 */
function collectUses(messages: readonly Message[], skills: Skills, recorded: readonly Use[]): Uses {
  const paths = new Map<string, number>();
  const names = new Map<string, number>();
  let seq = 0;
  for (const use of recorded) {
    if ("path" in use) paths.set(use.path, seq++);
    else names.set(use.skill, seq++);
  }
  messages.forEach((message, index) => {
    for (const base of skills.invoked.get(index) ?? []) paths.set(`${base}/SKILL.md`, seq++);
    for (const command of skills.commands.get(index) ?? []) names.set(command, seq++);
    for (const use of message.toolUses ?? []) {
      if (use.tool === "Skill") {
        const base = skills.calls.get(use);
        const skill = use.input.skill;
        if (base !== undefined) paths.set(`${base}/SKILL.md`, seq++);
        else if (typeof skill === "string" && skill !== "") names.set(skill, seq++);
      } else if (use.tool === "Read") {
        const path = use.input.file_path;
        if (typeof path === "string" && isRuleFile(path) && !isUnderAgents(path)) {
          paths.set(path, seq++);
        }
      }
    }
  });
  return { paths, skills: names };
}

/**
 * Where the loop's most recent `/sdlc:orchestrate` run stands after the transcript, starting from
 * where the state file left it. An invocation, as a `Skill` call or a slash command, opens a run,
 * and an `Agent` call after one ends its opening, so its opening files are no longer reloaded. A
 * reload message is no invocation.
 */
function orchestrateState(messages: readonly Message[], recorded: Orchestrate): Orchestrate {
  let state = recorded;
  for (const message of messages) {
    if (message.role === "user" && !isReload(message)) {
      if (commandNames(message.text).includes(ORCHESTRATE)) state = "opening";
    }
    for (const use of message.toolUses ?? []) {
      if (use.tool === "Skill" && use.input.skill === ORCHESTRATE) state = "opening";
      else if (use.tool === "Agent" && state !== "none") state = "opened";
    }
  }
  return state;
}

/** True for a path ending in one of `OPENING_FILES`, under whichever directory holds the plugin. */
function isOpeningFile(path: string): boolean {
  return OPENING_FILES.some((file) => path.endsWith(file));
}

/** True for a Markdown file under a `rules/` or `skills/` directory. */
function isRuleFile(path: string): boolean {
  return path.endsWith(".md") && RULE_DIRS.some((dir) => path.includes(dir));
}

/** True for a file opened under an `agents/` directory, which is not reloaded. */
function isUnderAgents(path: string): boolean {
  return path.includes(AGENTS_DIR);
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
 * A slash command's `<command-name>` tag is then paired with a base directory no call took whose
 * last directory is the skill's name, in the tag's own message or else in the user message right
 * after it, so a skill whose tag and expansion arrive apart is recorded once, by its file. A tag
 * left unpaired records the skill by its name.
 *
 * The harness keeps a skill's expansion out of the messages a `session.compact` hook receives,
 * for a `Skill` call and a slash command alike: the call's result reads `Launching skill: <name>`
 * and the slash command's message holds only its `<command-message>`, `<command-name>` and
 * `<command-args>` tags. So most slash commands are recorded by name.
 */
function resolveSkills(messages: readonly Message[]): Skills {
  const calls = new Map<ToolUse, string>();
  const invoked = new Map<number, string[]>();
  const tags = new Map<number, string[]>();
  messages.forEach((message, index) => {
    if (message.role === "assistant" || isReload(message)) return;
    invoked.set(index, baseDirs(message.text));
    tags.set(index, commandNames(message.text));
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
  const paired = new Set<string>();
  const commands = new Map<number, string[]>();
  for (const [index, names] of tags) {
    const unpaired = names.filter((name) => {
      const skill = name.slice(name.indexOf(":") + 1);
      for (const at of [index, index + 1]) {
        const bases = invoked.get(at) ?? [];
        const found = bases.findIndex(
          (base, i) => !paired.has(`${at}:${i}`) && baseName(base) === skill,
        );
        if (found >= 0) {
          paired.add(`${at}:${found}`);
          return false;
        }
      }
      return true;
    });
    if (unpaired.length > 0) commands.set(index, unpaired);
  }
  return { calls, invoked, commands };
}

/** Every skill base directory a text names, in order, without a trailing slash. */
function baseDirs(text: string): string[] {
  return [...text.matchAll(SKILL_BASE)].map((match) => match[1].trim().replace(/\/+$/, ""));
}

/** The skill name in every `<command-name>` tag a text holds, in order, without its slash. */
function commandNames(text: string): string[] {
  return [...text.matchAll(COMMAND_NAME)].map((match) => match[1]);
}

/**
 * Resolves a skill known only by name to its `SKILL.md`. A plugin skill `<plugin>:<name>`
 * resolves to `skills/<name>/SKILL.md` in the plugin's directory, as `pluginDir` finds it. A
 * name with no plugin prefix resolves under the project's `.claude/skills/`, then under
 * `~/.claude/skills/`, then in an installed plugin, as `pluginSkill` finds it, and with a file in
 * none of them is a built-in command and resolves to nothing. A plugin whose directory cannot be
 * found, or an installed-plugin registry that cannot be read, resolves to an item carrying the
 * error.
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
    if (home !== "" && (await $.fs.exists(user))) return { label: user, seq };
    const plugin = await pluginSkill($, name, home);
    return plugin === undefined ? undefined : { label: plugin, seq };
  } catch (err) {
    return { label: `skill ${name}`, seq, error: errorText(err) };
  }
}

/**
 * The first installed plugin's `skills/<name>/SKILL.md` that exists: the hook's own plugin's,
 * then that of each `<plugin>@<marketplace>` `~/.claude/plugins/installed_plugins.json` records
 * an install of, in the file's order, each in `~/.claude/plugins/cache/<marketplace>/<plugin>/`
 * at the version `installedVersion` picks.
 * Resolves to nothing when no plugin has the skill or the registry does not exist, and rejects
 * when the registry cannot be read or parsed.
 */
async function pluginSkill($: Mods, name: string, home: string): Promise<string | undefined> {
  const own = `${$.plugin.root}/skills/${name}/SKILL.md`;
  if (await $.fs.exists(own)) return own;
  if (home === "") return undefined;
  const registry = `${home}/.claude/plugins/installed_plugins.json`;
  if (!(await $.fs.exists(registry))) return undefined;
  const plugins = await readRegistry($, registry);
  const root = await $.session.root();
  for (const [id, installs] of Object.entries(plugins)) {
    const at = id.lastIndexOf("@");
    const version = installedVersion(installs, root);
    if (at <= 0 || version === undefined) continue;
    const dir = `${home}/.claude/plugins/cache/${id.slice(at + 1)}/${id.slice(0, at)}/${version}`;
    const file = `${dir}/skills/${name}/SKILL.md`;
    if (await $.fs.exists(file)) return file;
  }
  return undefined;
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
 * that `installedVersion` picks. Rejects when that file cannot be read or parsed, or records no
 * such install.
 */
async function cachedPluginDir($: Mods, plugin: string, home: string): Promise<string> {
  const marketplace = baseName(dirName(dirName($.plugin.root)));
  const id = `${plugin}@${marketplace}`;
  const registry = `${home}/.claude/plugins/installed_plugins.json`;
  const plugins = await readRegistry($, registry);
  const version = installedVersion(plugins[id], await $.session.root());
  if (version === undefined) throw new Error(`${registry} records no installed version of ${id}`);
  return `${home}/.claude/plugins/cache/${marketplace}/${plugin}/${version}`;
}

/**
 * The `plugins` map of `installed_plugins.json`, by `<plugin>@<marketplace>`. Rejects when the
 * file cannot be read or parsed.
 */
async function readRegistry($: Mods, registry: string): Promise<Record<string, unknown>> {
  const text = await $.fs.read(registry);
  let plugins: unknown;
  try {
    plugins = JSON.parse(text)?.plugins;
  } catch (err) {
    throw new Error(`${registry}: ${errorText(err)}`);
  }
  return typeof plugins === "object" && plugins !== null
    ? (plugins as Record<string, unknown>)
    : {};
}

/**
 * The version of the install among `installs` whose `projectPath` is the session's root, or else
 * of the install with no `projectPath`, or `undefined` when neither records one.
 */
function installedVersion(installs: unknown, root: string): string | undefined {
  const list = (Array.isArray(installs) ? installs : []) as Install[];
  const install =
    list.find((entry) => entry?.projectPath === root) ??
    list.find((entry) => entry?.projectPath === undefined || entry?.projectPath === null);
  const version = install?.version;
  return typeof version === "string" && version !== "" ? version : undefined;
}

/**
 * Resolves `reload-after-compact-token-budget` over the sdlc config tiers, highest tier
 * winning. A tier that does not exist contributes nothing. A tier that cannot be read, or that
 * `parseTier` refuses, adds an error naming the path, and the caller uses no budget at all.
 */
async function readBudget($: Mods, home: string): Promise<{ budget: number; errors: string[] }> {
  const xdg = await $.env.get("XDG_CONFIG_HOME");
  const configHome = xdg !== undefined && xdg !== "" ? xdg : `${home}/.config`;
  const root = await $.session.root();
  const tiers = [
    `${configHome}/sdlc/user-config.yml`,
    `${root}/.sdlc/repo-config.yml`,
    `${root}/.sdlc/user-config.yml`,
  ];
  let budget = DEFAULT_BUDGET;
  const errors: string[] = [];
  for (const path of tiers) {
    let text: string;
    try {
      if (!(await $.fs.exists(path))) continue;
      text = await $.fs.read(path);
    } catch (err) {
      errors.push(`${path}: ${errorText(err)}`);
      continue;
    }
    const tier = parseTier(text);
    if (tier.error !== undefined) errors.push(`${path}: ${tier.error}`);
    else if (tier.value !== undefined) budget = tier.value;
  }
  return { budget, errors };
}

/**
 * Reads `schema-version` off its own top-level line and the budget off its budget line, as
 * `skills/lib/sdlc-config.md` → "The keys" and "Reading" state, and validates both. Every line
 * that contains `BUDGET_KEY`, a comment included, is a budget line, valid only as `BUDGET_LINE`
 * and only once. Of every other line only `schema-version`'s is read, so the rest of the file's
 * YAML is left to the orchestrator.
 */
function parseTier(text: string): { value?: number; error?: string } {
  let schema: string | undefined;
  let value: number | undefined;
  let budgetError: string | undefined;
  for (const raw of text.split("\n")) {
    const line = raw.replace(/\r$/, "");
    if (line.includes(BUDGET_KEY)) {
      if (budgetError !== undefined) continue;
      const budgetMatch = BUDGET_LINE.exec(line);
      if (budgetMatch === null) {
        budgetError = `\`${line}\` is not a \`${BUDGET_KEY}: <digits>\` line`;
      } else if (value !== undefined) {
        budgetError = `\`${BUDGET_KEY}\` is set more than once`;
      } else if (Number(budgetMatch[1]) < MIN_BUDGET) {
        budgetError = `\`${BUDGET_KEY}\` is ${budgetMatch[1]}, below the floor of ${MIN_BUDGET}`;
      } else {
        value = Number(budgetMatch[1]);
      }
      continue;
    }
    const schemaMatch = SCHEMA_LINE.exec(line);
    if (schemaMatch !== null) schema = (schemaMatch[2] ?? "").replace(/\s+#.*$/, "").trim();
  }
  if (schema === undefined) return { error: "`schema-version` is absent" };
  if (!/^\d+$/.test(schema))
    return { error: `\`schema-version\` is \`${schema}\`, not an integer` };
  if (Number(schema) < SCHEMA_PIN) {
    return { error: `\`schema-version\` is ${schema}, lower than the pin ${SCHEMA_PIN}` };
  }
  if (budgetError !== undefined) return { error: budgetError };
  return value === undefined ? {} : { value };
}

/** True for a reload message this hook appended at an earlier compaction. */
function isReload(message: Message): boolean {
  return message.role === "user" && message.text.startsWith(MARKER);
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
