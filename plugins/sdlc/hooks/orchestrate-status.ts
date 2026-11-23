// Pins one status line under the prompt while an `/sdlc:orchestrate` run is under way, and these
// comments are the one description of it. `/orchestrate-status` turns the line off and on for the
// session. The line reads, its parts joined by ` · ` and any part with nothing to show left out:
//
//   PR #812 (#745 #746) · code loop r2 · theorem-based-pr-reviewer › disprove 15/31 theorems
//
// - The lead is the current PR with its issue set, `PR #812 (#745 #746)`, or `PR #812` while
//   the set is unknown; before a PR exists it is the issue set alone, `#745 #746`. `issuesOf`
//   names the set's sources: during `readiness` and `plan` the main loop's `Skill` calls of
//   `sdlc:orchestrate-readiness`, from `seed` onward the reviewer's `--issues` and the
//   developer's issues in main-loop briefs, and for a new PR before its first reviewer brief the
//   developer brief of the one batch that has no PR yet, when exactly one batch has none.
// - The phase follows, and in a loop carries the round: that of the loop's latest reviewer; with
//   none fixed, while an `issue-fixer` or `code-documenter` row is on the line, the PR's latest
//   round when the progress read reports it `reviewed`; otherwise, before the loop's first
//   reviewer runs, the next round after the PR's latest in either loop, as `nextRound` reads it,
//   so a fresh code loop shows `r1` and a doc loop after code rounds r1 and r2 shows `r3`.
// - Then the running agents, grouped by the main-loop agent each descends from. A reviewer row
//   shows its round's stage, with `<settled>/<members> theorems` in `disprove` and `verify`,
//   whether or not the reviewer itself is listed as running while it waits on its fan-out; an
//   `issue-fixer` or `code-documenter` row names the round it answers, `issue-fixer › r1
//   findings`, when the phase carries one of the first two rounds above; a row with neither to
//   show, the seed reviewer's included, names its running children.
// - Every other PR with a running agent trails as ` | #<n> <phase>`, or ` | #<n>` while it has no
//   phase, with no issue set.
//
// Apart from answering that command, every hook only observes: each returns what `next(e)`
// resolved, unchanged, and none denies or rewrites anything. Each runs its own work through
// `guard`, so no failure of that work reaches the hook's caller or keeps `next(e)` from running.
// The hook reads no state file by a path of its own: round state reaches it only through
// `sdlc-agent-result-persist --mode progress`.
//
// Every function a hook passes `$` to is declared at the top level of this file, which is the only
// place the engine lets `$` be passed to.

/** The command that turns the line off and on. */
export const COMMAND = "orchestrate-status";
/** The command's answer to an argument other than `on` and `off`. */
export const USAGE = "usage: /orchestrate-status [on|off]";

const PLUGIN = "sdlc";
const REVIEWER = "theorem-based-pr-reviewer";
const DEVELOPER = "issue-developer";
const DOCS_WRITER = "docs-writer";
const READINESS_SKILL = `${PLUGIN}:orchestrate-readiness`;
/** The agents whose row names the round whose findings they answer. */
const ANSWERING = new Set([`${PLUGIN}:issue-fixer`, `${PLUGIN}:code-documenter`]);
const PLAN_FILE = "/skills/orchestrate/lib/plan.md";
const PERSIST = "sdlc-agent-result-persist";
const TICK_MS = 5000;
const SEPARATOR = " · ";
const NESTED = " › ";
// The first `<host>/<owner>/<repo>#<n>` in a brief, its host holding at least one dot so that a
// repo-relative path followed by a `#` is not read as one.
const PR_REF =
  /(?<![\w./-])[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+#\d+(?!\w)/;
const DOC_MODE = /--mode documentation(?![\w-])/;
const PR_FLAG = /(?<![\w-])--pr(?![\w-])/;
// A reviewer brief's `--issues` and the operands after it, up to the next flag or the line's end.
const ISSUES_FLAG = /(?<![\w-])--issues((?:[ \t]+(?!--)\S+)+)/;
// The issues a developer brief's opening sentence names.
const DEVELOPER_ISSUES = /You are fixing issues?\s([\s\S]*?)\s+in\s+this\s+repo/;
// The issues a `docs-writer` new-branch brief's opening sentence names.
const NEW_BRANCH_ISSUES =
  /You are writing the documentation for issues?\s([\s\S]*?)\s+in\s+this\s+repo/;
const RUNNING = new Set(["pending", "running", "waiting", "idle"]);
// The stages the line shows with their theorem counts; any other stage shows by name alone.
const COUNTED_STAGES = new Set(["disprove", "verify"]);
// The most lines `writeLog` keeps waiting for a write that does not throw; older ones are dropped.
const MAX_UNWRITTEN = 20;
/** What `errorText` gives for a thrown value that cannot be turned into text. */
export const NO_TEXT = "a thrown value with no text";

type Loop = "code loop" | "doc loop";
type Phase =
  | Loop
  | "readiness"
  | "plan"
  | "seed"
  | "develop"
  | "memory scrub"
  | "merge readiness"
  | "finalizer"
  | "monitor"
  | "cleanup";

/** The phase a main-loop spawn of each `sdlc:` agent sets, where the brief does not decide it. */
const SPAWN_PHASES = new Map<string, Phase>([
  ["issue-developer", "develop"],
  ["code-documenter", "code loop"],
  ["issue-fixer", "code loop"],
  ["docs-writer", "doc loop"],
  ["agent-memory-scrubber", "memory scrub"],
  ["pr-merge-readiness", "merge readiness"],
  ["pr-finalizer", "finalizer"],
  ["pr-monitor", "monitor"],
]);
/**
 * The agents whose spawn sets `doc loop` when its brief carries `--mode documentation`, and
 * `code loop` when it does not, but for the reviewer's seed spawn, which sets `seed`.
 */
const MODE_PHASED = new Set(["style-checker", REVIEWER]);

/** One agent as `$.agent.list()` lists it: `parentId` is absent for one the main loop spawned. */
type AgentInfo = { id: string; status: string; type: string; parentId?: string };
type Timer = { cancel: () => void };

/** The host modules the hooks reach through `$`. */
type Mods = {
  plugin: { root: string };
  agent: { list: () => Promise<readonly AgentInfo[]> };
  process: {
    run: (argv: readonly string[]) => Promise<{ exitCode: number; stdout: string; stderr: string }>;
  };
  command: {
    register: (spec: {
      name: string;
      description: string;
      argumentHint?: string;
      immediate?: true;
    }) => Promise<void>;
  };
  clock: { every: (ms: number, fn: () => void) => Timer };
  ui: {
    status: (text: string | undefined) => void;
    log: (text: string, options?: { to: "transcript" | "debug" }) => void;
  };
};

type SkillEvent = { skill: string; pluginName?: string };
type ReadEvent = { agentId?: string; file_path?: unknown };
type SkillCallEvent = { agentId?: string; skill?: unknown; args?: unknown };
type SpawnEvent = { subagentType: string; prompt: string; parentAgentId?: string };
type SpawnResult = { agentId?: string; deny?: string };
type TurnEvent = { agentId?: string };
type CommandEvent = { args: string };

/** Passes an event on to the hooks after this one, and Claude Code, resolving to its result. */
type Next<E, R = unknown> = (e: E) => Promise<R>;
/** Registers `hook` on `event`, or with `matcher` only for the events it matches. */
type On = {
  (event: string, hook: unknown): unknown;
  (event: string, matcher: object, hook: unknown): unknown;
};

/** One line of `sdlc-agent-result-persist --mode progress`, without its round type. */
type Progress = { round: number; stage: string; settled: string; members: string };
/**
 * A main-loop spawn as `record` takes it: its agent's definition, the PR its brief named or
 * `NO_PR`, the issues its brief named as `briefIssues` reads them, the batch its brief starts as
 * `batchOf` reads it, whether its brief carries `--mode documentation`, whether it is the reviewer's
 * seed spawn, the agent id it resolved, and the number `signalsBegun` gave it when it began.
 */
type Spawned = {
  type: string;
  pr: string;
  issues?: string[];
  batch?: string[];
  isDocMode: boolean;
  isSeed: boolean;
  agentId?: string;
  order: number;
};
/**
 * One group of the line's agents: a main-loop agent that is running or has a running descendant,
 * by its id and definition.
 */
type Row = { id: string; type: string };
/**
 * What an await is tied to, with the errors of the progress reads begun under it, oldest first,
 * and the main-loop spawns that resolved under it while no run was under way and started none, in
 * the order they resolved.
 */
type Epoch = { failedReads: string[]; pending: Spawned[] };
/**
 * One main-loop signal the run has recorded: the epoch it was recorded under, the number
 * `signalsBegun` gave it when its hook began, the PR a spawn's brief named or `NO_PR`, and the
 * phase it sets, if any. A spawn's signal also carries its agent's definition, the agent id it
 * resolved, the issues its brief named and the batch its brief starts. The `orchestrate` and
 * `orchestrate-cleanup` prompts and the plan read are signals of the whole run, and carry no PR:
 * each sets the phase of whichever PR is current when the line is drawn, `NO_PR` included, and of
 * no other PR. A readiness check's signal carries the one issue it was run on, and nothing else.
 */
type Signal = {
  epoch: Epoch;
  order: number;
  pr?: string;
  phase?: Phase;
  spawn?: { type: string; agentId?: string; issues?: string[]; batch?: string[] };
  readied?: string;
};

/** The key of the phase and agents of the work no brief names a PR for. */
const NO_PR = "";

/** Whether the line is drawn: on when the session starts, and set only by the command. */
let isOn = true;
/** Whether an orchestrate run is under way. */
let isRun = false;
/**
 * The epoch the `agent.spawn` hook and `redraw` capture before they await, dropping what an await
 * resolved to once `supersede` has replaced it. The `orchestrate` skill's prompt and `endRun`
 * replace it. A main-loop spawn that starts a run while none is under way keeps it, and records,
 * with its own, those of the epoch's pending spawns whose agents are still running, so every such
 * spawn begun while no run was under way is recorded in the run one of them starts, whichever
 * resolves first, and one whose agent has finished changes nothing in it.
 */
let epoch: Epoch = { failedReads: [], pending: [] };
/**
 * How many signal hooks — spawn, skill prompt, `Read` and `Skill` call — have begun this session,
 * which numbers each in the order it began.
 */
let signalsBegun = 0;
/**
 * The run's signals, appended as each is recorded, never changed, and emptied only by a run's
 * start. The current PR, each PR's phase and issue set, each loop's round, with the rounds
 * `reviewerRound` fixed, and the PR of each agent are derived from them each time they are read,
 * by the order the signals began in rather than the order they were recorded in.
 */
const signals: Signal[] = [];
/** The round each reviewer reviews, fixed when the line first sees its review tree running. */
const reviewerRound = new Map<string, number>();
/**
 * The line each PR's last successful progress read printed, by PR, or `undefined` for a read that
 * printed none; each read replaces the one before it. Emptied by a run's start.
 */
const latestProgress = new Map<string, Progress | undefined>();
/** How many redraws have begun this session, which numbers each in the order it began. */
let redrawsBegun = 0;
/** The number `redrawsBegun` gave the latest-begun redraw that drew the line, or 0. */
let drawnOrder = 0;
/** The redraw timer `syncTimer` started, or `undefined` while none runs. */
let timer: Timer | undefined;
/**
 * The lines whose `$.ui.log` write threw, oldest first, which `writeLog` writes before its own.
 * A run's start drops them, so that no line queued before it is written during it.
 */
const unwritten: { text: string; options?: { to: "transcript" | "debug" } }[] = [];

/**
 * Registers the `/orchestrate-status` command at session start and the hooks that answer it and
 * follow the run: the `orchestrate` and `orchestrate-cleanup` skill prompts, the main loop's read
 * of the plan lib file, its `Skill` calls of the readiness check, every agent spawn, every turn's
 * end, and the session's end.
 */
export function register(on: On): void {
  on("session.start", async ($: Mods, e: unknown, next: Next<unknown>) => {
    await guard($, () => registerCommand($));
    return next(e);
  });

  on("command.run", { command: COMMAND }, async ($: Mods, e: CommandEvent) => ({
    text: await toggle($, e.args),
  }));

  on("skill.prompt", async ($: Mods, e: SkillEvent, next: Next<SkillEvent>) => {
    const order = ++signalsBegun;
    const result = await next(e);
    await guard($, () => skillPrompt($, e, order));
    return result;
  });

  on("tool.call", { tool: "Read" }, async ($: Mods, e: ReadEvent, next: Next<ReadEvent>) => {
    const order = ++signalsBegun;
    const result = await next(e);
    await guard($, () => mainRead($, e, order));
    return result;
  });

  on(
    "tool.call",
    { tool: "Skill" },
    async ($: Mods, e: SkillCallEvent, next: Next<SkillCallEvent>) => {
      const order = ++signalsBegun;
      const result = await next(e);
      await guard($, () => mainSkill($, e, order));
      return result;
    },
  );

  on("agent.spawn", async ($: Mods, e: SpawnEvent, next: Next<SpawnEvent, SpawnResult>) => {
    const started = epoch;
    const order = ++signalsBegun;
    const result = await next(e);
    // A spawn that resolves once its epoch has been superseded was begun before a run's end or a
    // fresh orchestrate prompt, whether or not a run was under way then, and sets nothing after it.
    if (e.parentAgentId === undefined && result.deny === undefined && epoch === started) {
      await guard($, () => mainSpawn($, e, result, order));
    }
    return result;
  });

  on("turn.complete", async ($: Mods, e: TurnEvent, next: Next<TurnEvent>) => {
    const result = await next(e);
    await guard($, () => turnComplete($, e));
    return result;
  });

  on("session.end", async ($: Mods, e: unknown, next: Next<unknown>) => {
    await guard($, () => endRun($));
    return next(e);
  });
}

/**
 * Runs a hook's own work, resolving whether it resolves, rejects or throws, so that no failure of
 * it reaches the hook: a failure is written to the debug log instead.
 */
async function guard($: Mods, work: () => Promise<void>): Promise<void> {
  try {
    await work();
  } catch (err) {
    writeLog($, `${COMMAND}: ${errorText(err)}`, { to: "debug" });
  }
}

/**
 * Writes `text` with `$.ui.log`, after any lines whose write threw, oldest first. A write that
 * throws keeps its line and every one after it for the next call, rather than throwing, and only
 * the newest `MAX_UNWRITTEN` lines are kept.
 */
function writeLog($: Mods, text: string, options?: { to: "transcript" | "debug" }): void {
  unwritten.push({ text, options });
  if (unwritten.length > MAX_UNWRITTEN) unwritten.splice(0, unwritten.length - MAX_UNWRITTEN);
  while (unwritten.length > 0) {
    const line = unwritten[0];
    try {
      $.ui.log(line.text, line.options);
    } catch {
      // A failed write has no log to report it in, so the line waits for the next write.
      return;
    }
    unwritten.shift();
  }
}

/** Registers `/orchestrate-status`, logging to the debug log when the registration rejects. */
async function registerCommand($: Mods): Promise<void> {
  try {
    await $.command.register({
      name: COMMAND,
      description: "Turn the sdlc orchestrate status line off or on",
      argumentHint: "[on|off]",
      immediate: true,
    });
  } catch (err) {
    writeLog($, `${COMMAND}: the command did not register: ${errorText(err)}`, { to: "debug" });
  }
}

/**
 * Follows a skill prompt: `orchestrate` starts a fresh run in readiness, and `orchestrate-cleanup`
 * during a run puts the whole run in cleanup. `order` is the number `signalsBegun` gave the
 * prompt's hook when it began.
 */
async function skillPrompt($: Mods, e: SkillEvent, order: number): Promise<void> {
  if (isSdlcSkill(e, "orchestrate")) {
    supersede();
    startRun();
    signals.push({ epoch, order, phase: "readiness" });
    await redraw($);
  } else if (isRun && isSdlcSkill(e, "orchestrate-cleanup")) {
    signals.push({ epoch, order, phase: "cleanup" });
    await redraw($);
  }
}

/**
 * Follows a `Read`: the main loop's read of the plan lib file during a run puts the whole run in
 * plan. `order` is the number `signalsBegun` gave the read's hook when it began.
 */
async function mainRead($: Mods, e: ReadEvent, order: number): Promise<void> {
  const path = e.file_path;
  if (isRun && e.agentId === undefined && typeof path === "string" && path.endsWith(PLAN_FILE)) {
    signals.push({ epoch, order, phase: "plan" });
    await redraw($);
  }
}

/**
 * Follows a `Skill` call: the main loop's call of `sdlc:orchestrate-readiness` during a run records
 * the one issue its `args` name, which `issuesOf` leads the line with until a brief names issues.
 * `order` is the number `signalsBegun` gave the call's hook when it began.
 */
async function mainSkill($: Mods, e: SkillCallEvent, order: number): Promise<void> {
  if (!isRun || e.agentId !== undefined || e.skill !== READINESS_SKILL) return;
  const issue = typeof e.args === "string" ? issueNumbers(e.args)[0] : undefined;
  if (issue === undefined) return;
  signals.push({ epoch, order, readied: issue });
  await redraw($);
}

/**
 * Follows a turn's end during a run: the main loop's turn ending while the phase the line shows,
 * the current PR's as `statusLine` reads it, is `cleanup` ends the run, and any other turn's end
 * redraws the line.
 */
async function turnComplete($: Mods, e: TurnEvent): Promise<void> {
  const isCleanup = phaseOf(currentPr(), true) === "cleanup";
  if (isRun && e.agentId === undefined && isCleanup) await endRun($);
  else if (isRun) await redraw($);
}

/**
 * Answers `/orchestrate-status`: `off` turns the line off, `on` on, and no argument flips it,
 * each answered with the state it left. Any other argument changes nothing and is answered with
 * the usage line. Turning the line off clears it and stops the timer; turning it on redraws it.
 */
async function toggle($: Mods, args: string): Promise<string> {
  const arg = args.trim();
  if (arg !== "" && arg !== "on" && arg !== "off") return USAGE;
  isOn = arg === "" ? !isOn : arg === "on";
  if (isOn) {
    await redraw($);
  } else {
    stopTimer();
    showLine($, "");
  }
  return `orchestrate status line: ${isOn ? "on" : "off"}`;
}

/** True for the skill prompt of the sdlc skill `name`. */
function isSdlcSkill(e: SkillEvent, name: string): boolean {
  return e.skill === `${PLUGIN}:${name}` || (e.pluginName === PLUGIN && e.skill === name);
}

/**
 * Replaces the epoch, so that every await begun before now is dropped when it settles, and no
 * spawn pending in it is recorded.
 */
function supersede(): void {
  epoch = { failedReads: [], pending: [] };
}

/** Starts a run with nothing yet known of it, and no log line left waiting from before it. */
function startRun(): void {
  isRun = true;
  signals.length = 0;
  reviewerRound.clear();
  latestProgress.clear();
  unwritten.length = 0;
}

/**
 * Ends any run under way, superseding its epoch, clears the line and stops the timer, whether or
 * not a run was on.
 */
async function endRun($: Mods): Promise<void> {
  supersede();
  isRun = false;
  stopTimer();
  showLine($, "");
}

/**
 * Follows a spawn the main loop made. A spawn of any `sdlc:` agent but the reviewer, or of the
 * reviewer on its seed brief, starts a run when none is under way, so a session resumed mid-run
 * shows the line again from its next spawn, and a standalone review, whose brief always carries
 * `--pr`, shows none. The seed brief is the reviewer's one brief that names no PR, by reference or
 * by `--pr`. Any other spawn that resolves while no run is under way is kept pending in the epoch
 * and draws nothing. A later spawn that starts a run in that epoch reads which agents are running,
 * then records its own spawn and each pending one whose agent is among them; a pending spawn that
 * resolved no agent id, or whose agent has finished, is dropped. The list is read again while a
 * spawn joined the pending ones during the read and no run has started, and the last read is used
 * with no await after its check, so every pending spawn is judged by a list read after it joined. A
 * rejected list is written to the debug log and counts as no agent running. During a run the spawn
 * is recorded and the line redrawn. `order` is the number `signalsBegun` gave the spawn when it
 * began.
 */
async function mainSpawn(
  $: Mods,
  e: SpawnEvent,
  result: SpawnResult,
  order: number,
): Promise<void> {
  const pr = PR_REF.exec(e.prompt)?.[0] ?? NO_PR;
  const isReviewer = e.subagentType === `${PLUGIN}:${REVIEWER}`;
  const issues = briefIssues(e.subagentType, e.prompt);
  const spawned: Spawned = {
    type: e.subagentType,
    pr,
    issues,
    batch: batchOf(e.subagentType, pr, e.prompt, issues),
    isDocMode: DOC_MODE.test(e.prompt),
    isSeed: isReviewer && pr === NO_PR && !PR_FLAG.test(e.prompt),
    agentId: result.agentId,
    order,
  };
  if (!isRun) {
    if (!e.subagentType.startsWith(`${PLUGIN}:`) || (isReviewer && !spawned.isSeed)) {
      epoch.pending.push(spawned);
      return;
    }
    const started = epoch;
    let waiting: number;
    let agents: AgentInfo[];
    do {
      waiting = started.pending.length;
      agents = await runningAgents($);
      if (epoch !== started) return;
    } while (!isRun && started.pending.length !== waiting);
    // A sibling that started the run during the read has already recorded the pending spawns.
    if (!isRun) {
      startRun();
      const live = new Set(agents.map((agent) => agent.id));
      const replayed = started.pending
        .splice(0)
        .filter((earlier) => earlier.agentId !== undefined && live.has(earlier.agentId));
      for (const each of [...replayed, spawned]) record(each);
      await redraw($);
      return;
    }
  }
  record(spawned);
  await redraw($);
}

/** Appends a main-loop spawn to the run's signals, with the phase its agent sets. */
function record(spawned: Spawned): void {
  signals.push({
    epoch,
    order: spawned.order,
    pr: spawned.pr,
    phase: spawned.isSeed ? "seed" : spawnPhase(spawned.type, spawned.isDocMode),
    spawn: {
      type: spawned.type,
      agentId: spawned.agentId,
      issues: spawned.issues,
      batch: spawned.batch,
    },
  });
}

/**
 * The issues a main-loop brief names, or `undefined` for none: the operands of a reviewer brief's
 * `--issues`, and the issues a developer brief's opening sentence names. No other brief is read
 * for issues.
 */
function briefIssues(type: string, prompt: string): string[] | undefined {
  const pattern =
    type === `${PLUGIN}:${REVIEWER}`
      ? ISSUES_FLAG
      : type === `${PLUGIN}:${DEVELOPER}`
        ? DEVELOPER_ISSUES
        : undefined;
  const named = pattern?.exec(prompt)?.[1];
  const issues = named === undefined ? [] : issueNumbers(named);
  return issues.length === 0 ? undefined : issues;
}

/**
 * The issues of the batch a main-loop brief starts, or `undefined` for a brief that starts none. A
 * developer brief starts a batch of the issues `briefIssues` gave it, and a `docs-writer` brief
 * naming no PR — the new-branch brief of a batch with no code to implement — one of the issues its
 * opening sentence names. A batch either brief starts whose issues do not parse holds none.
 * `issues` are the issues `briefIssues` gave the brief. `issuesOf` reads a `docs-writer` batch's
 * issues only to tell whether the batch has a PR, never as an issue set to show.
 */
function batchOf(
  type: string,
  pr: string,
  prompt: string,
  issues: string[] | undefined,
): string[] | undefined {
  if (type === `${PLUGIN}:${DEVELOPER}`) return issues ?? [];
  if (type !== `${PLUGIN}:${DOCS_WRITER}` || pr !== NO_PR) return undefined;
  const named = NEW_BRANCH_ISSUES.exec(prompt)?.[1];
  return named === undefined ? [] : issueNumbers(named);
}

/**
 * The issue numbers in `text`, each once, in the order they first appear: the digits that end each
 * of its space- or comma-separated words, after any trailing punctuation, so `#745`, `745` and an
 * issue URL each give `745`.
 */
function issueNumbers(text: string): string[] {
  const found: string[] = [];
  for (const word of text.split(/[\s,]+/)) {
    const issue = /(\d+)\W*$/.exec(word)?.[1];
    if (issue !== undefined && !found.includes(issue)) found.push(issue);
  }
  return found;
}

/** The signals recorded under the current epoch, in the order they began. */
function runSignals(): Signal[] {
  return signals.filter((signal) => signal.epoch === epoch).sort((a, b) => a.order - b.order);
}

/**
 * The run's signal that `pick` accepts and that began last, or `undefined` for none. A signal
 * recorded under an epoch since superseded is never one.
 */
function latest(pick: (signal: Signal) => boolean): Signal | undefined {
  let found: Signal | undefined;
  for (const signal of signals) {
    if (signal.epoch !== epoch || !pick(signal)) continue;
    if (found === undefined || signal.order > found.order) found = signal;
  }
  return found;
}

/**
 * The PR named by the brief of the run's main-loop spawn that began last, or `NO_PR` when that
 * brief named none or the run has recorded no spawn.
 */
function currentPr(): string {
  return latest((signal) => signal.spawn !== undefined)?.pr ?? NO_PR;
}

/**
 * The phase set for `pr` by the run's signal that began last of those that set one for it, or, with
 * `isCurrent`, of those that set one for it or for the whole run.
 */
function phaseOf(pr: string, isCurrent = false): Phase | undefined {
  return latest(
    (signal) =>
      (signal.pr === pr || (isCurrent && signal.pr === undefined)) && signal.phase !== undefined,
  )?.phase;
}

/** The main-loop spawn signal that resolved the agent `id`, or `undefined` for none. */
function spawnOf(id: string): Signal | undefined {
  return latest((signal) => signal.spawn?.agentId === id);
}

/** The PR the main loop spawned the agent `id` for, or `undefined` for an agent it did not. */
function prOfAgent(id: string): string | undefined {
  return spawnOf(id)?.pr;
}

/**
 * The issue set the line leads with for `pr`, or none. `rows` are the line's rows, as `rowsOf`
 * builds them.
 *
 * For a PR it is the `--issues` of the latest main-loop reviewer brief for that PR. Before that
 * brief, it is the issues of the one batch that has no PR yet, when exactly one has none. A batch
 * is one `batchOf` reads off a developer brief or a `docs-writer` new-branch brief, the same issues
 * counting once, and it has a PR once a reviewer brief for any PR names one of its issues; a batch
 * holding no issue never has one. The batch's issues are shown only when it is a developer brief's
 * and its brief began before the first brief naming the PR. So a doc-only batch, counted while it
 * has no PR, gives no PR its issues, and a PR named before the one open batch's brief, whose own
 * batch this run never recorded, shows none of that batch's. With more than one batch lacking a
 * PR the PR has no set until its first reviewer brief.
 *
 * Before any PR — `NO_PR` — it is the issues of the PR-less main-loop briefs, the seed's and the
 * developer's, whose agent has a row, and none when no such agent has one, so a PR-less agent
 * whose brief names no issues, such as a doc-only batch's `docs-writer`, is not given an earlier
 * batch's. Before the first such brief, during `readiness` and `plan`, it is the issues of the
 * main loop's readiness checks, in the order the checks were called.
 */
function issuesOf(pr: string, rows: readonly Row[]): string[] {
  const run = runSignals();
  const briefed = run.filter((signal) => signal.spawn?.issues !== undefined);
  const isReview = (signal: Signal) => signal.spawn?.type === `${PLUGIN}:${REVIEWER}`;
  const issues = (signal: Signal) => signal.spawn?.issues ?? [];
  if (pr !== NO_PR) {
    const own = briefed.filter((signal) => signal.pr === pr && isReview(signal)).at(-1);
    if (own !== undefined) return issues(own);
    const claimed = new Set(
      briefed.filter((signal) => signal.pr !== NO_PR && isReview(signal)).flatMap(issues),
    );
    const open = new Map<string, Signal>();
    for (const signal of run) {
      const batch = signal.spawn?.batch;
      if (batch === undefined || batch.some((issue) => claimed.has(issue))) continue;
      open.set(batch.length === 0 ? `@${signal.order}` : batch.join(" "), signal);
    }
    if (open.size !== 1) return [];
    const [source] = open.values();
    const named = run.find((signal) => signal.pr === pr);
    const isDeveloper = source.spawn?.type === `${PLUGIN}:${DEVELOPER}`;
    const isEarlier = named !== undefined && source.order < named.order;
    return isDeveloper && isEarlier ? (source.spawn?.batch ?? []) : [];
  }
  const early = briefed.filter((signal) => signal.pr === NO_PR);
  if (early.length === 0) {
    return unique(run.flatMap((signal) => (signal.readied === undefined ? [] : [signal.readied])));
  }
  const shown = new Set(rows.map((row) => row.id));
  return unique(early.filter((signal) => shown.has(signal.spawn?.agentId ?? "")).flatMap(issues));
}

/** `items`, each once, in the order each first appears. */
function unique(items: readonly string[]): string[] {
  return [...new Set(items)];
}

/**
 * The round a loop of `pr` shows before its first reviewer runs: one after the PR's latest round in
 * either loop, which is the higher of the round its last progress read reported and every round a
 * reviewer for it has been fixed at, or 0 when neither is known.
 */
function nextRound(pr: string): number {
  let latestSeen = latestProgress.get(pr)?.round ?? 0;
  for (const signal of runSignals()) {
    const id = signal.spawn?.agentId;
    if (signal.pr !== pr || signal.spawn?.type !== `${PLUGIN}:${REVIEWER}` || id === undefined) {
      continue;
    }
    latestSeen = Math.max(latestSeen, reviewerRound.get(id) ?? 0);
  }
  return latestSeen + 1;
}

/**
 * The round an `issue-fixer` or `code-documenter` of `pr` answers when no reviewer round is fixed
 * for it, as in a session resumed at such a spawn: the PR's latest round when its last progress
 * read reported that round `reviewed`, or none.
 */
function reviewedRound(pr: string): number | undefined {
  const progress = latestProgress.get(pr);
  return progress?.stage === "reviewed" ? progress.round : undefined;
}

/**
 * The round shown for `pr` in `loop`: that fixed for the reviewer spawned for `pr` in `loop` that
 * began last of those whose round is fixed, provided it began after every signal that put `pr` in
 * the other loop. A round belongs to the loop it was reviewed in, so entering the other loop drops
 * it, and any other phase keeps it for when the PR comes back to that loop.
 */
function roundOf(pr: string, loop: Loop): number | undefined {
  const left = latest(
    (signal) => signal.pr === pr && isLoop(signal.phase) && signal.phase !== loop,
  );
  const reviewer = latest((signal) => {
    const id = signal.spawn?.agentId;
    return (
      signal.pr === pr &&
      signal.phase === loop &&
      signal.spawn?.type === `${PLUGIN}:${REVIEWER}` &&
      id !== undefined &&
      reviewerRound.has(id) &&
      (left === undefined || signal.order > left.order)
    );
  });
  const id = reviewer?.spawn?.agentId;
  return id === undefined ? undefined : reviewerRound.get(id);
}

/** True for the code loop and the doc loop, the phases a review round belongs to. */
function isLoop(phase: Phase | undefined): phase is Loop {
  return phase === "code loop" || phase === "doc loop";
}

/**
 * The phase a main-loop spawn of `type` sets, `isDocMode` saying whether its brief carries
 * `--mode documentation`, or none.
 */
function spawnPhase(type: string, isDocMode: boolean): Phase | undefined {
  if (!type.startsWith(`${PLUGIN}:`)) return undefined;
  const name = type.slice(PLUGIN.length + 1);
  if (MODE_PHASED.has(name)) return isDocMode ? "doc loop" : "code loop";
  return SPAWN_PHASES.get(name);
}

/**
 * Draws the line from what the run has reached, while the line is on and a run is under way. A
 * rejected `$.agent.list` draws the line with no agent on it, and a failed progress read leaves
 * that PR's round and stage off it; any other failure is written to the debug log. A redraw
 * during which its epoch is superseded draws nothing, and leaves the later run's state as it
 * found it, and so does one that settles after a redraw begun later than it has drawn the line.
 */
async function redraw($: Mods): Promise<void> {
  if (!isOn || !isRun) return;
  const started = epoch;
  const order = ++redrawsBegun;
  try {
    const listed = await listAgents($);
    if (epoch !== started) return;
    const running = listed.filter(isRunning);
    const rows = rowsOf(listed, running);
    const review = await reviewStages($, rows, started);
    if (review === undefined || !isOn || !isRun || epoch !== started) return;
    if (order < drawnOrder) return;
    drawnOrder = order;
    syncTimer($, running);
    showLine($, statusLine(rows, running, review));
  } catch (err) {
    writeLog($, `${COMMAND}: the line was not drawn: ${errorText(err)}`, { to: "debug" });
  }
}

/** Every agent `$.agent.list()` lists, or none, with a debug-log line, when the list rejects. */
async function listAgents($: Mods): Promise<readonly AgentInfo[]> {
  try {
    return await $.agent.list();
  } catch (err) {
    writeLog($, `${COMMAND}: the agent list was not read: ${errorText(err)}`, { to: "debug" });
    return [];
  }
}

/** The session's agents that are running, or none when the list rejects. */
async function runningAgents($: Mods): Promise<AgentInfo[]> {
  return (await listAgents($)).filter(isRunning);
}

/** True for an agent `$.agent.list()` lists in a status that counts as running. */
function isRunning(agent: AgentInfo): boolean {
  return RUNNING.has(agent.status);
}

/**
 * The line's rows: for each running agent, in list order, the main-loop agent it descends from,
 * each once. A nested agent is attributed to the PR of its nearest main-loop ancestor alone — its
 * own brief is never read — so a reviewer's disprovers and verifiers, and the seed's generator and
 * assessor, keep their reviewer's row on the line whatever `$.agent.list()` reports for the
 * reviewer while it waits on them.
 */
function rowsOf(listed: readonly AgentInfo[], running: readonly AgentInfo[]): Row[] {
  const byId = new Map(listed.map((agent) => [agent.id, agent]));
  const rows = new Map<string, Row>();
  for (const agent of running) {
    const row = mainAncestor(agent, byId);
    if (row !== undefined && !rows.has(row.id)) rows.set(row.id, row);
  }
  return [...rows.values()];
}

/**
 * The main-loop agent `agent` descends from, `agent` itself for one with no parent: found by
 * walking `parentId` through `byId` until it reaches an agent with no parent, or an id a main-loop
 * spawn resolved, whether or not `byId` lists that agent. `undefined` when the walk reaches an id
 * neither lists nor resolved, or comes back to an id it has passed.
 */
function mainAncestor(agent: AgentInfo, byId: Map<string, AgentInfo>): Row | undefined {
  const passed = new Set<string>();
  let current = agent;
  while (current.parentId !== undefined) {
    const parentId = current.parentId;
    const spawned = spawnOf(parentId)?.spawn;
    if (spawned !== undefined) {
      return { id: parentId, type: byId.get(parentId)?.type ?? spawned.type };
    }
    const parent = byId.get(parentId);
    if (parent === undefined || passed.has(parentId)) return undefined;
    passed.add(parentId);
    current = parent;
  }
  return { id: current.id, type: current.type };
}

/** Runs the 5-second redraw while any `sdlc:` agent is running, and no timer while none is. */
function syncTimer($: Mods, agents: readonly AgentInfo[]): void {
  const isBusy = agents.some((agent) => agent.type.startsWith(`${PLUGIN}:`));
  if (isBusy && timer === undefined) timer = $.clock.every(TICK_MS, () => void redraw($));
  else if (!isBusy) stopTimer();
}

/** Cancels any redraw timer and forgets it, so that `syncTimer` starts a fresh one when needed. */
function stopTimer(): void {
  timer?.cancel();
  timer = undefined;
}

/** Pins `text` as the plugin's status line, or clears the line when `text` is empty. */
function showLine($: Mods, text: string): void {
  $.ui.status(text === "" ? undefined : text);
}

/**
 * Reads the review round of each PR that has a row the read is run for, and returns the stage to
 * show beside each reviewer row, by its id, and the PRs whose read failed. `rows` are the line's
 * rows, as `rowsOf` builds them.
 *
 * The read is run for a PR whose main-loop reviewer has a row — the reviewer or any of its
 * descendants is running, whatever `$.agent.list()` reports for the reviewer itself — and for a PR
 * in a loop with no round of its own yet, as `roundOf` reads it, that has any row, so `nextRound`
 * has the PR's latest round and `reviewedRound` its stage. Each successful read's line is kept in
 * `latestProgress`. The seed reviewer names no PR, so its row gets no read.
 *
 * A reviewer's round is fixed when its row is first seen: the round after the one the read
 * reports when that round is `reviewed`, round 1 when the read prints nothing, and the reported
 * round otherwise. Its stage shows only while the read reports that round in a stage other than
 * `reviewed` and `-`, and carries `<settled>/<members> theorems` in `disprove` and `verify`. A
 * failed read's error is kept in `started`'s failed reads, and the first one kept there is written
 * as one `$.ui.log` line, so a run writes one such line, naming its own error.
 *
 * `roundOf`, `nextRound` and `reviewedRound` read the rounds kept here, so a redraw calls this
 * before drawing the line.
 *
 * `started` is the epoch the redraw began in. A read that settles once it has been superseded
 * records nothing and returns `undefined`: its result is dropped, and its error is kept in
 * `started` alone, which no later run reads.
 */
async function reviewStages(
  $: Mods,
  rows: readonly Row[],
  started: Epoch,
): Promise<{ stages: Map<string, string>; failed: Set<string> } | undefined> {
  const stages = new Map<string, string>();
  const failed = new Set<string>();
  const read = new Map<string, Progress | undefined>();
  const current = currentPr();
  for (const row of rows) {
    const pr = prOfAgent(row.id);
    if (pr === undefined || pr === NO_PR || failed.has(pr)) continue;
    const isReviewer = row.type === `${PLUGIN}:${REVIEWER}`;
    const phase = phaseOf(pr, pr === current);
    if (!isReviewer && !(isLoop(phase) && roundOf(pr, phase) === undefined)) continue;
    if (!read.has(pr)) {
      try {
        const progress = await readProgress($, pr);
        if (epoch !== started) return undefined;
        read.set(pr, progress);
        latestProgress.set(pr, progress);
      } catch (err) {
        started.failedReads.push(errorText(err));
        if (epoch !== started) return undefined;
        if (started.failedReads.length === 1) writeLog($, `${COMMAND}: ${started.failedReads[0]}`);
        failed.add(pr);
        continue;
      }
    }
    if (!isReviewer) continue;
    const progress = read.get(pr);
    let round = reviewerRound.get(row.id);
    if (round === undefined) {
      round = progress === undefined ? 1 : progress.round + (progress.stage === "reviewed" ? 1 : 0);
      reviewerRound.set(row.id, round);
    }
    if (
      progress === undefined ||
      progress.round !== round ||
      progress.stage === "reviewed" ||
      progress.stage === "-"
    ) {
      continue;
    }
    stages.set(
      row.id,
      COUNTED_STAGES.has(progress.stage)
        ? `${progress.stage} ${progress.settled}/${progress.members} theorems`
        : progress.stage,
    );
  }
  return { stages, failed };
}

/**
 * The line `sdlc-agent-result-persist --mode progress` prints for `pr`, or `undefined` when it
 * prints none. Rejects when the command cannot run, exits non-zero, or prints another line.
 */
async function readProgress($: Mods, pr: string): Promise<Progress | undefined> {
  const argv = [`${$.plugin.root}/bin/${PERSIST}`, "--mode", "progress", "--pr", pr];
  const { exitCode, stdout, stderr } = await $.process.run(argv);
  const command = `${PERSIST} --mode progress --pr ${pr}`;
  if (exitCode !== 0) throw new Error(`${command} exited ${exitCode}: ${oneLine(stderr.trim())}`);
  const line = stdout.replace(/\n$/, "");
  if (line === "") return undefined;
  const [round, , stage, settled, members, ...rest] = line.split("\t");
  if (!/^\d+$/.test(round) || members === undefined || rest.length > 0) {
    throw new Error(`${command} printed \`${oneLine(line)}\`, not a progress line`);
  }
  return { round: Number(round), stage, settled, members };
}

/**
 * The line: the lead, the current PR's phase, and its rows, joined by ` · ` with any part that has
 * nothing to show left out. The lead is `PR #<n> (<issue set>)`, or `PR #<n>` while `issuesOf`
 * gives the PR no set, and with no current PR the issue set alone, each issue as `#<n>` and
 * space-separated. A `code loop` or `doc loop` phase carries ` r<n>` after it, unless the PR's
 * progress read failed this redraw: the round `roundOf` gives the PR in that loop, the one under
 * review; when it gives none and the PR has an `issue-fixer` or `code-documenter` row, the round
 * `reviewedRound` gives; and `nextRound`'s when neither gives one. An `issue-fixer` or
 * `code-documenter` row carries ` › r<n> findings` when the phase carries one of the first two,
 * for that round. Then comes
 * ` | #<n> <phase>` for every other PR with a row, or ` | #<n>` for one with no phase. `rows` are
 * the line's rows, as `rowsOf` builds them from `running`, and `review` holds the reviewer stages
 * and the PRs whose progress read failed this redraw, as `reviewStages` returns them.
 */
function statusLine(
  rows: readonly Row[],
  running: readonly AgentInfo[],
  review: { stages: Map<string, string>; failed: Set<string> },
): string {
  const prOf = (row: Row) => prOfAgent(row.id) ?? NO_PR;
  const current = currentPr();
  const parts: string[] = [];
  const issues = issuesOf(current, rows)
    .map((issue) => `#${issue}`)
    .join(" ");
  const pr = `PR #${prNumber(current)}`;
  if (current === NO_PR) parts.push(issues);
  else parts.push(issues === "" ? pr : `${pr} (${issues})`);
  const phase = phaseOf(current, true);
  const hasRound = isLoop(phase) && !review.failed.has(current);
  const group = rows.filter((row) => prOf(row) === current);
  const isAnswering = group.some((row) => ANSWERING.has(row.type));
  const reviewed = hasRound
    ? (roundOf(current, phase) ?? (isAnswering ? reviewedRound(current) : undefined))
    : undefined;
  if (phase !== undefined) {
    parts.push(hasRound ? `${phase} r${reviewed ?? nextRound(current)}` : phase);
  }
  parts.push(agentNames(group, running, review.stages, reviewed));
  const others = [...new Set(rows.map(prOf))].filter((pr) => pr !== NO_PR && pr !== current);
  const tail = others
    .map((pr) => {
      const other = phaseOf(pr);
      return other === undefined ? ` | #${prNumber(pr)}` : ` | #${prNumber(pr)} ${other}`;
    })
    .join("");
  return (parts.filter((part) => part !== "").join(SEPARATOR) + tail).trim();
}

/**
 * `group`'s rows by definition, comma-separated, each name once with `×<n>` after it when it has
 * more than one row. A reviewer is followed by ` › ` and its stage from `stages`, when it has one
 * there; an `issue-fixer` or `code-documenter` by ` › r<answered> findings`, when `answered` is
 * given; and any other row with running children — the seed reviewer's generator and assessor
 * among them — by ` › ` and their names, counted the same way. `running` is the running agents.
 */
function agentNames(
  group: readonly Row[],
  running: readonly AgentInfo[],
  stages: Map<string, string>,
  answered: number | undefined,
): string {
  const byName = new Map<string, Row[]>();
  for (const row of group) {
    const name = shortName(row.type);
    byName.set(name, [...(byName.get(name) ?? []), row]);
  }
  return [...byName]
    .map(([name, members]) => {
      const head = counted(name, members.length);
      const stage = stages.get(members[0].id);
      if (stage !== undefined) return `${head}${NESTED}${stage}`;
      if (ANSWERING.has(members[0].type) && answered !== undefined) {
        return `${head}${NESTED}r${answered} findings`;
      }
      const ids = new Set(members.map((row) => row.id));
      const children = running.filter(
        (agent) => agent.parentId !== undefined && ids.has(agent.parentId),
      );
      if (children.length === 0) return head;
      const childCounts = new Map<string, number>();
      for (const child of children) {
        const childName = shortName(child.type);
        childCounts.set(childName, (childCounts.get(childName) ?? 0) + 1);
      }
      const childNames = [...childCounts].map(([child, n]) => counted(child, n)).join(", ");
      return `${head}${NESTED}${childNames}`;
    })
    .join(", ");
}

/** `name`, followed by `×<n>` when `n` is more than one. */
function counted(name: string, n: number): string {
  return n > 1 ? `${name}×${n}` : name;
}

/** An agent's definition without the `sdlc:` prefix. */
function shortName(type: string): string {
  return type.startsWith(`${PLUGIN}:`) ? type.slice(PLUGIN.length + 1) : type;
}

/** The number after a PR reference's `#`. */
function prNumber(pr: string): string {
  return pr.slice(pr.lastIndexOf("#") + 1);
}

/**
 * An `Error`'s message, or any other thrown value as a string, or `NO_TEXT` for a value that
 * throws when read or turned into a string, so that a `catch` calling this cannot throw itself.
 */
function errorText(err: unknown): string {
  try {
    const text = err instanceof Error ? err.message : err;
    return typeof text === "string" ? text : String(text);
  } catch {
    // The value has no text to give, so the line names that in its place.
    return NO_TEXT;
  }
}

/** `text` on one line, its lines joined with ` | `. */
function oneLine(text: string): string {
  return text.split(/\r\n|\r|\n/).join(" | ");
}
