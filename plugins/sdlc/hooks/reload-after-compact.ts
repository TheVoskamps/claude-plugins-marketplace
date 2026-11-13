// After a compaction, appends to the compacted conversation the full text of the skills, agent
// definitions and rule files the compacting loop loaded before it, so the loop works from those
// files rather than from the summary's truncated account of them.

// The key and its default must match the key table in `skills/lib/sdlc-config.md`, and
// `SCHEMA_PIN` the pin its "Reading" section states, since the orchestrator reads them there.
export const DEFAULT_BUDGET = 100000;
export const BUDGET_KEY = "reload-after-compact-token-budget";
/** The opening of every reload message, by which a later compaction recognises one. */
export const MARKER = "<reload-after-compact>";

const SCHEMA_PIN = 1;
const MANIFEST_HEADING = "Files, most recently used first:";
const APPENDED = "appended below";
const NOT_APPENDED = "not appended: read it before acting on it";
const UNREADABLE = "could not be read";
const SKILL_BASE = /Base directory for this skill: (.+)/;
const RULE_DIRS = ["/rules/", "/skills/", "/agents/"];

type ToolUse = { tool: string; input: Record<string, unknown>; text?: string };
type Message = { role: "user" | "assistant"; text: string; toolUses?: readonly ToolUse[] };

type Mods = {
  plugin: { name: string; root: string };
  env: { get: (name: string) => Promise<string | undefined> };
  session: { root: () => Promise<string> };
  fs: {
    read: (path: string) => Promise<string>;
    exists: (path: string) => Promise<boolean>;
    list: (path: string) => Promise<{ name: string; kind: string }[]>;
  };
};

type Compacted = { messages?: readonly Message[]; skip?: string };
type CompactEvent = { trigger: string; messages: readonly Message[] };

/** One file to reload: `label` is its absolute path, or a description when no path resolved. */
type Item = { label: string; seq: number; error?: string };

/** What the walk over a transcript finds, each keyed to the position of its last use. */
type Uses = { paths: Map<string, number>; agents: Map<string, number> };

type Next = (e: CompactEvent) => Promise<Compacted>;
type On = (event: string, hook: unknown) => { catch: (handler: unknown) => void };

/**
 * Registers the `session.compact` hook, which lets the compaction run and then appends one reload
 * message after its messages, replacing any reload message already among them.
 */
export function register(on: On): void {
  // The `.catch` handler makes a throw or a timeout leave the compaction as `next` resolved it,
  // with no reload.
  on("session.compact", async ($: Mods, e: CompactEvent, next: Next) => {
    const result = await next(e);
    if (result.skip !== undefined || result.messages === undefined) return result;
    // A result can already carry a reload message, as one core reuses from a precompute does, and
    // the fresh one supersedes it, since its manifest names every file the old one did.
    const kept = result.messages.filter((message) => !isReload(message));
    const text = await reloadText($, e.messages);
    if (text === "") return { ...result, messages: kept };
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
  const uses = collectUses(messages);
  const items: Item[] = [];
  for (const [path, seq] of uses.paths) items.push({ label: path, seq });
  const pluginDirs = skillPluginDirs(messages);
  for (const [type, seq] of uses.agents) {
    const item = await agentItem($, type, seq, pluginDirs, home);
    if (item !== undefined) items.push(item);
  }
  const kept = mergeByLabel(items).filter((item) => !isReinjected(item.label, home));
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
    "The conversation was just compacted, and its summary truncates or omits the skills, agent " +
      "definitions and rule files the conversation loaded before it. Their full text follows; act " +
      "on it rather than on the summary's account of them. A file listed as not appended is past " +
      `the reload budget of ${budget} tokens: read it with the Read tool before acting on it.`,
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
 * Walks the transcript oldest first and records the last position at which each skill file,
 * rule file and agent type was used. A reload message from an earlier compaction counts as a
 * use of every file its manifest names, so a second compaction reloads them again.
 */
function collectUses(messages: readonly Message[]): Uses {
  const paths = new Map<string, number>();
  const agents = new Map<string, number>();
  let seq = 0;
  messages.forEach((message, index) => {
    if (isReload(message)) {
      for (const path of manifestPaths(message.text).reverse()) paths.set(path, seq++);
    }
    for (const use of message.toolUses ?? []) {
      if (use.tool === "Skill") {
        const base = skillBaseDir(messages, index, use);
        if (base !== undefined) paths.set(`${base}/SKILL.md`, seq++);
      } else if (use.tool === "Agent" || use.tool === "Task") {
        const type = use.input.subagent_type;
        if (typeof type === "string" && type !== "") agents.set(type, seq++);
      } else if (use.tool === "Read") {
        const path = use.input.file_path;
        if (typeof path === "string" && isRuleFile(path)) paths.set(path, seq++);
      }
    }
  });
  return { paths, agents };
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
 * The base directory a Skill call's result names, searched in the call's own result and then in
 * the messages up to the next assistant message, where the harness puts the expanded skill text.
 */
function skillBaseDir(
  messages: readonly Message[],
  index: number,
  use: ToolUse,
): string | undefined {
  const texts = [use.text ?? ""];
  for (let i = index + 1; i < messages.length && messages[i].role !== "assistant"; i++) {
    texts.push(messages[i].text);
  }
  for (const text of texts) {
    const match = SKILL_BASE.exec(text);
    if (match !== null) return match[1].trim().replace(/\/+$/, "");
  }
  return undefined;
}

/** Each plugin's directory, as the base directory of a skill it loaded names it. */
function skillPluginDirs(messages: readonly Message[]): Map<string, string> {
  const dirs = new Map<string, string>();
  messages.forEach((message, index) => {
    for (const use of message.toolUses ?? []) {
      const skill = use.input.skill;
      if (use.tool !== "Skill" || typeof skill !== "string" || !skill.includes(":")) continue;
      const base = skillBaseDir(messages, index, use);
      const cut = base?.lastIndexOf("/skills/") ?? -1;
      if (base !== undefined && cut > 0)
        dirs.set(skill.slice(0, skill.indexOf(":")), base.slice(0, cut));
    }
  });
  return dirs;
}

/**
 * Resolves an agent type to its definition file. A project agent with no file under the project's
 * `.claude/agents/` is a built-in one and resolves to nothing. A plugin whose directory cannot be
 * found resolves to an item carrying the error.
 */
async function agentItem(
  $: Mods,
  type: string,
  seq: number,
  pluginDirs: Map<string, string>,
  home: string,
): Promise<Item | undefined> {
  const colon = type.indexOf(":");
  if (colon < 0) {
    try {
      const path = `${await $.session.root()}/.claude/agents/${type}.md`;
      return (await $.fs.exists(path)) ? { label: path, seq } : undefined;
    } catch (err) {
      return { label: `agent ${type}`, seq, error: errorText(err) };
    }
  }
  const plugin = type.slice(0, colon);
  const name = type.slice(colon + 1);
  let dir = pluginDirs.get(plugin);
  if (dir === undefined && plugin === $.plugin.name) dir = $.plugin.root;
  if (dir === undefined) {
    try {
      dir = await cachedPluginDir($, plugin, home);
    } catch (err) {
      return { label: `agent ${type}`, seq, error: errorText(err) };
    }
  }
  return { label: `${dir}/agents/${name}.md`, seq };
}

/**
 * A plugin's directory in the cache of the marketplace this hook module was installed from:
 * `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>`, at the highest version present.
 * Rejects when the plugin's cache directory cannot be listed or holds no version directory.
 */
async function cachedPluginDir($: Mods, plugin: string, home: string): Promise<string> {
  const marketplace = baseName(dirName(dirName($.plugin.root)));
  const base = `${home}/.claude/plugins/cache/${marketplace}/${plugin}`;
  const versions = (await $.fs.list(base))
    .filter((entry) => entry.kind === "dir")
    .map((entry) => entry.name);
  if (versions.length === 0) throw new Error(`no installed version under ${base}`);
  versions.sort(compareVersions);
  return `${base}/${versions[versions.length - 1]}`;
}

/** Orders `x.y.z` versions numerically, part by part. */
function compareVersions(a: string, b: string): number {
  const left = a.split(".");
  const right = b.split(".");
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    const x = left[i] ?? "";
    const y = right[i] ?? "";
    const delta = /^\d+$/.test(x) && /^\d+$/.test(y) ? Number(x) - Number(y) : x.localeCompare(y);
    if (delta !== 0) return delta;
  }
  return 0;
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
 * Reads one tier's top-level keys and validates `schema-version` and the budget key, as
 * `skills/lib/sdlc-config.md` → "Reading" states. Every other key is left to the orchestrator.
 */
function parseTier(text: string): { value?: number; error?: string } {
  let schema: string | undefined;
  let value: string | undefined;
  for (const raw of text.split("\n")) {
    const line = raw.replace(/\r$/, "");
    if (/^\s*(#.*)?$/.test(line) || /^\s/.test(line) || line === "---") continue;
    const match = /^([A-Za-z0-9_-]+):(?:\s+(.*))?$/.exec(line);
    if (match === null) return { error: `the YAML is malformed at \`${line}\`` };
    const scalar = (match[2] ?? "").replace(/\s+#.*$/, "").trim();
    if (match[1] === "schema-version") schema = scalar;
    if (match[1] === BUDGET_KEY) value = scalar;
  }
  if (schema === undefined) return { error: "`schema-version` is absent" };
  if (!/^\d+$/.test(schema))
    return { error: `\`schema-version\` is \`${schema}\`, not an integer` };
  if (Number(schema) < SCHEMA_PIN) {
    return { error: `\`schema-version\` is ${schema}, lower than the pin ${SCHEMA_PIN}` };
  }
  if (value === undefined) return {};
  if (!/^[1-9]\d*$/.test(value))
    return { error: `\`${BUDGET_KEY}\` is \`${value}\`, not a positive integer` };
  return { value: Number(value) };
}

/** True for a reload message this hook appended at an earlier compaction. */
function isReload(message: Message): boolean {
  return message.role === "user" && message.text.startsWith(MARKER);
}

/** The paths an earlier reload message's manifest names, in its order. */
function manifestPaths(text: string): string[] {
  const lines = text.split("\n");
  const start = lines.indexOf(MANIFEST_HEADING);
  if (start < 0) return [];
  const paths: string[] = [];
  const entry = new RegExp(`^- (/.+?) \\((?:${APPENDED}|${NOT_APPENDED}|${UNREADABLE})`);
  for (const line of lines.slice(start + 1)) {
    if (!line.startsWith("- ")) break;
    const match = entry.exec(line);
    if (match !== null) paths.push(match[1]);
  }
  return paths;
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
