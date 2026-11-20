// Pins one status line under the prompt while an `/sdlc:orchestrate` run is under way: the PR the
// run is on, the phase it is in, and the agents running, with a review round's stage and theorem
// counts beside its reviewer. `/orchestrate-status` turns the line off and on for the session.
// Apart from answering that command, every hook only observes: each returns what `next(e)`
// resolved, unchanged, and none denies or rewrites anything. Each runs its own work through
// `guard`, so no failure of that work reaches the hook's caller or keeps `next(e)` from running.
//
// Every function a hook passes `$` to is declared at the top level of this file, which is the only
// place the engine lets `$` be passed to.

/** The command that turns the line off and on. */
export const COMMAND = "orchestrate-status";
/** The command's answer to an argument other than `on` and `off`. */
export const USAGE = "usage: /orchestrate-status [on|off]";

const PLUGIN = "sdlc";
const REVIEWER = "theorem-based-pr-reviewer";
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
  ["theorem-generator", "seed"],
  ["theorem-assessor", "seed"],
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
 * `code loop` when it does not.
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

/** One line of `sdlc-agent-result-persist --mode progress`. */
type Progress = { round: number; stage: string; settled: string; members: string };
/**
 * A main-loop spawn as `record` takes it: its agent's definition, the PR its brief named or
 * `NO_PR`, whether its brief carries `--mode documentation`, and the agent id it resolved.
 */
type Spawned = { type: string; pr: string; isDocMode: boolean; agentId?: string };
/**
 * What an await is tied to, with the errors of the progress reads begun under it, oldest first,
 * and the main-loop spawns that resolved under it while no run was under way and started none, in
 * the order they resolved.
 */
type Epoch = { failedReads: string[]; pending: Spawned[] };

/** The key of the phase and agents of the work no brief names a PR for. */
const NO_PR = "";

/** Whether the line is drawn: on when the session starts, and set only by the command. */
let isOn = true;
/** Whether an orchestrate run is under way. */
let isRun = false;
/**
 * The epoch the `agent.spawn` hook and `redraw` capture before they await, dropping what an await
 * resolved to once `supersede` has replaced it. The `orchestrate` skill's prompt and `endRun`
 * replace it. A main-loop spawn that starts a run while none is under way keeps it, and records the
 * epoch's pending spawns before its own, so every spawn begun while no run was under way is
 * recorded in the run one of them starts, whichever resolves first.
 */
let epoch: Epoch = { failedReads: [], pending: [] };
/** The PR the most recent main-loop spawn's brief named, or `NO_PR` when it named none. */
let currentPr = NO_PR;
/** The phase of each PR by its reference, and under `NO_PR` that of the work no PR is named for. */
const phases = new Map<string, Phase>();
/** The PR each agent the main loop spawned was spawned for, by the id `agent.spawn` resolved. */
const prOfAgent = new Map<string, string>();
/** The loop each reviewer the main loop spawned reviews in, set by its spawn. */
const reviewerLoop = new Map<string, Loop>();
/** The round each reviewer reviews, fixed when the line first sees it running. */
const reviewerRound = new Map<string, number>();
/** The round of each PR's latest reviewer, and the loop it reviewed in. */
const prRound = new Map<string, { loop: Loop; round: number }>();
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
 * of the plan lib file, every agent spawn, every turn's end, and the session's end.
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
    const result = await next(e);
    await guard($, () => skillPrompt($, e));
    return result;
  });

  on("tool.call", { tool: "Read" }, async ($: Mods, e: ReadEvent, next: Next<ReadEvent>) => {
    const result = await next(e);
    await guard($, () => mainRead($, e));
    return result;
  });

  on("agent.spawn", async ($: Mods, e: SpawnEvent, next: Next<SpawnEvent, SpawnResult>) => {
    const started = epoch;
    const result = await next(e);
    // A spawn that resolves once its epoch has been superseded belongs to an earlier run, and sets
    // nothing in a later one.
    if (e.parentAgentId === undefined && result.deny === undefined && epoch === started) {
      await guard($, () => mainSpawn($, e, result));
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
 * during a run sets the current PR's phase to cleanup.
 */
async function skillPrompt($: Mods, e: SkillEvent): Promise<void> {
  if (isSdlcSkill(e, "orchestrate")) {
    supersede();
    startRun();
    phases.set(NO_PR, "readiness");
    await redraw($);
  } else if (isRun && isSdlcSkill(e, "orchestrate-cleanup")) {
    phases.set(currentPr, "cleanup");
    await redraw($);
  }
}

/** Follows a `Read`: the main loop's read of the plan lib file during a run sets plan. */
async function mainRead($: Mods, e: ReadEvent): Promise<void> {
  const path = e.file_path;
  if (isRun && e.agentId === undefined && typeof path === "string" && path.endsWith(PLAN_FILE)) {
    phases.set(currentPr, "plan");
    await redraw($);
  }
}

/**
 * Follows a turn's end during a run: the main loop's turn ending in cleanup ends the run, and any
 * other turn's end redraws the line.
 */
async function turnComplete($: Mods, e: TurnEvent): Promise<void> {
  if (isRun && e.agentId === undefined && phases.get(currentPr) === "cleanup") await endRun($);
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
  currentPr = NO_PR;
  phases.clear();
  prOfAgent.clear();
  reviewerLoop.clear();
  reviewerRound.clear();
  prRound.clear();
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
 * Follows a spawn the main loop made. A spawn of any `sdlc:` agent but the reviewer starts a run
 * when none is under way, so a session resumed mid-run shows the line again from its next spawn,
 * and a standalone review shows none. Any other spawn that resolves while no run is under way is
 * kept pending in the epoch and draws nothing, and a later spawn that starts a run in that epoch
 * records the pending spawns, in the order they resolved, before its own. During a run the spawn
 * is recorded and the line redrawn.
 */
async function mainSpawn($: Mods, e: SpawnEvent, result: SpawnResult): Promise<void> {
  const spawned: Spawned = {
    type: e.subagentType,
    pr: PR_REF.exec(e.prompt)?.[0] ?? NO_PR,
    isDocMode: DOC_MODE.test(e.prompt),
    agentId: result.agentId,
  };
  if (!isRun) {
    if (!e.subagentType.startsWith(`${PLUGIN}:`) || e.subagentType === `${PLUGIN}:${REVIEWER}`) {
      epoch.pending.push(spawned);
      return;
    }
    startRun();
    for (const earlier of epoch.pending.splice(0)) record(earlier);
  }
  record(spawned);
  await redraw($);
}

/**
 * Records a main-loop spawn in the run under way: makes its PR the current one, records its agent
 * under that PR, and sets the phase its agent sets. A reviewer's spawn also records the loop it
 * reviews in.
 */
function record(spawned: Spawned): void {
  currentPr = spawned.pr;
  const phase = spawnPhase(spawned.type, spawned.isDocMode);
  if (spawned.agentId !== undefined) {
    prOfAgent.set(spawned.agentId, currentPr);
    if (spawned.type === `${PLUGIN}:${REVIEWER}` && isLoop(phase)) {
      reviewerLoop.set(spawned.agentId, phase);
    }
  }
  if (phase !== undefined) {
    // A round belongs to the loop it was reviewed in, so entering the other loop drops it, and
    // any other phase keeps it for when the PR comes back to that loop.
    if (isLoop(phase) && prRound.get(currentPr)?.loop !== phase) prRound.delete(currentPr);
    phases.set(currentPr, phase);
  }
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
 * found it.
 */
async function redraw($: Mods): Promise<void> {
  if (!isOn || !isRun) return;
  const started = epoch;
  try {
    const agents = await runningAgents($);
    if (epoch !== started) return;
    const review = await reviewStages($, agents, started);
    if (review === undefined || !isOn || !isRun || epoch !== started) return;
    syncTimer($, agents);
    showLine($, statusLine(agents, review));
  } catch (err) {
    writeLog($, `${COMMAND}: the line was not drawn: ${errorText(err)}`, { to: "debug" });
  }
}

/** The session's agents that are running, or none, with a debug-log line, when the list rejects. */
async function runningAgents($: Mods): Promise<AgentInfo[]> {
  try {
    return (await $.agent.list()).filter((agent) => RUNNING.has(agent.status));
  } catch (err) {
    writeLog($, `${COMMAND}: the agent list was not read: ${errorText(err)}`, { to: "debug" });
    return [];
  }
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
 * Reads the review round of each PR that has a running reviewer the main loop spawned, and
 * returns the stage to show beside each such reviewer, by its id, and the PRs whose read failed.
 *
 * A reviewer's round is fixed when it is first seen running: the round after the one the read
 * reports when that round is `reviewed`, round 1 when the read prints nothing, and the reported
 * round otherwise. Its stage shows only while the read reports that round in a stage other than
 * `reviewed` and `-`. A failed read's error is kept in `started`'s failed reads, and the first
 * one kept there is written as one `$.ui.log` line, so a run writes one such line, naming its own
 * error.
 *
 * Each reviewer's round is also recorded as its PR's round, under the loop the reviewer's spawn
 * recorded, which is where `statusLine` reads the round it shows, so a redraw calls this before
 * drawing the line.
 *
 * `started` is the epoch the redraw began in. A read that settles once it has been superseded
 * records nothing and returns `undefined`: its result is dropped, and its error is kept in
 * `started` alone, which no later run reads.
 */
async function reviewStages(
  $: Mods,
  agents: readonly AgentInfo[],
  started: Epoch,
): Promise<{ stages: Map<string, string>; failed: Set<string> } | undefined> {
  const stages = new Map<string, string>();
  const failed = new Set<string>();
  const read = new Map<string, Progress | undefined>();
  for (const agent of agents) {
    if (agent.parentId !== undefined || agent.type !== `${PLUGIN}:${REVIEWER}`) continue;
    const pr = prOfAgent.get(agent.id);
    if (pr === undefined || pr === NO_PR || failed.has(pr)) continue;
    if (!read.has(pr)) {
      try {
        const progress = await readProgress($, pr);
        if (epoch !== started) return undefined;
        read.set(pr, progress);
      } catch (err) {
        started.failedReads.push(errorText(err));
        if (epoch !== started) return undefined;
        if (started.failedReads.length === 1) writeLog($, `${COMMAND}: ${started.failedReads[0]}`);
        failed.add(pr);
        continue;
      }
    }
    const progress = read.get(pr);
    let round = reviewerRound.get(agent.id);
    if (round === undefined) {
      round = progress === undefined ? 1 : progress.round + (progress.stage === "reviewed" ? 1 : 0);
      reviewerRound.set(agent.id, round);
    }
    const loop = reviewerLoop.get(agent.id);
    if (loop !== undefined) prRound.set(pr, { loop, round });
    if (
      progress === undefined ||
      progress.round !== round ||
      progress.stage === "reviewed" ||
      progress.stage === "-"
    ) {
      continue;
    }
    stages.set(
      agent.id,
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
 * The line: the current PR, its phase, and its running agents, joined by ` · ` with any part that
 * has nothing to show left out. A `code loop` or `doc loop` phase carries ` r<n>` after it when
 * the PR has a round recorded under that loop and its progress read did not fail this redraw.
 * Then comes ` | #<n> <phase>` for every other PR with a running agent the main loop spawned, or
 * ` | #<n>` for one with no phase. `review` holds the reviewer stages and the PRs whose progress
 * read failed this redraw, as `reviewStages` returns them.
 */
function statusLine(
  agents: readonly AgentInfo[],
  review: { stages: Map<string, string>; failed: Set<string> },
): string {
  const main = agents.filter((agent) => agent.parentId === undefined);
  const prOf = (agent: AgentInfo) => prOfAgent.get(agent.id) ?? NO_PR;
  const parts: string[] = [];
  if (currentPr !== NO_PR) parts.push(`PR #${prNumber(currentPr)}`);
  const phase = phases.get(currentPr);
  if (phase !== undefined) {
    const recorded = prRound.get(currentPr);
    parts.push(
      isLoop(phase) && recorded?.loop === phase && !review.failed.has(currentPr)
        ? `${phase} r${recorded.round}`
        : phase,
    );
  }
  const names = agentNames(
    main.filter((agent) => prOf(agent) === currentPr),
    agents,
    review.stages,
  );
  if (names !== "") parts.push(names);
  const others = [...new Set(main.map(prOf))].filter((pr) => pr !== NO_PR && pr !== currentPr);
  const tail = others
    .map((pr) => {
      const other = phases.get(pr);
      return other === undefined ? ` | #${prNumber(pr)}` : ` | #${prNumber(pr)} ${other}`;
    })
    .join("");
  return (parts.join(SEPARATOR) + tail).trim();
}

/**
 * `group`'s agents by definition, comma-separated, each name once with `×<n>` after it when it is
 * running more than once. A reviewer is followed by ` › ` and its stage from `stages`, when it
 * has one there, and any other agent with running children by ` › ` and their names, counted the
 * same way.
 */
function agentNames(
  group: readonly AgentInfo[],
  agents: readonly AgentInfo[],
  stages: Map<string, string>,
): string {
  const byName = new Map<string, AgentInfo[]>();
  for (const agent of group) {
    const name = shortName(agent.type);
    byName.set(name, [...(byName.get(name) ?? []), agent]);
  }
  return [...byName]
    .map(([name, members]) => {
      const head = counted(name, members.length);
      if (members[0].type === `${PLUGIN}:${REVIEWER}`) {
        const stage = stages.get(members[0].id);
        return stage === undefined ? head : `${head}${NESTED}${stage}`;
      }
      const ids = new Set(members.map((agent) => agent.id));
      const children = agents.filter(
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
