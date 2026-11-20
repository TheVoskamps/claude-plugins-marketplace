import { expect, mock, test } from "claude-code/testing";

import { COMMAND, NO_TEXT, register, USAGE } from "../hooks/orchestrate-status.ts";

const PR = "github.com/o/r#812";
const OTHER_PR = "github.com/o/r#813";
const ROOT = "/plugins/sdlc/0.91.0";
/** The progress read's executable, under whichever directory the plugin root is in a test. */
const PERSIST = "/bin/sdlc-agent-result-persist";
const TAB = "\t";

type Agent = { id: string; status: string; type: string; parentId?: string };

/** What the stubs below answer with, and what they saw the module do. */
type Host = {
  /** The text of every `$.ui.status` call, `undefined` for a clear. */
  lines: (string | undefined)[];
  logs: string[];
  /** The `argv` of every `$.process.run` call. */
  runs: string[][];
  registered: object[];
  /** What `$.agent.list()` resolves to. */
  agents: Agent[];
  /** What `$.process.run` resolves to. */
  progress: { exitCode: number; stdout: string; stderr: string };
  /** A reason to reject `$.agent.list` with, or `undefined` to answer `agents`. */
  refuseList?: string;
  /** A reason to reject `$.process.run` with, or `undefined` to answer `progress`. */
  refuseRun?: string;
  /** A reason to reject `$.ui.status` with, or `undefined` to record the line. */
  refuseStatus?: string;
  clock: { advance: (ms: number) => Promise<void> };
};

/**
 * Stubs everything the module reaches: each spawn is answered with the agent id `a<n>`, counting
 * from 1, and every event's own result is a value a test can tell came from its stub.
 */
function host(on): Host {
  const state: Host = {
    lines: [],
    logs: [],
    runs: [],
    registered: [],
    agents: [],
    progress: { exitCode: 0, stdout: "", stderr: "" },
    clock: mock.clock(on),
  };
  let spawned = 0;
  mock.env(on, {});
  on("ui.status", ($, e) => {
    if (state.refuseStatus !== undefined) return { deny: state.refuseStatus };
    state.lines.push(e.text);
    return { value: undefined };
  });
  on("ui.log", ($, e) => {
    state.logs.push(e.text);
    return { value: undefined };
  });
  on("agent.list", () =>
    state.refuseList !== undefined ? { deny: state.refuseList } : { value: state.agents },
  );
  on("process.run", ($, e) => {
    state.runs.push(e.argv);
    return state.refuseRun !== undefined ? { deny: state.refuseRun } : { value: state.progress };
  });
  on("command.register", ($, e) => {
    state.registered.push(e);
    return { value: undefined };
  });
  on("agent.spawn", () => ({ model: "claude-test", agentId: `a${++spawned}` }));
  on("skill.prompt", ($, e) => ({ text: `expanded ${e.skill}` }));
  on("tool.call", () => ({ result: "contents" }));
  on("turn.complete", () => ({ text: "turn stub" }));
  on("session.start", () => ({ cwd: "/work" }));
  on("session.end", () => ({ sessionId: "s1" }));
  return state;
}

/** The line the module last pinned, `undefined` when it last cleared it or pinned none. */
function shown(state: Host): string | undefined {
  return state.lines.at(-1);
}

function orchestrate($) {
  return $.skill.prompt({
    skill: "sdlc:orchestrate",
    text: "the skill",
    frontmatter: {},
    source: "plugin",
    pluginName: "sdlc",
  });
}

function cleanup($) {
  return $.skill.prompt({
    skill: "sdlc:orchestrate-cleanup",
    text: "the skill",
    frontmatter: {},
    source: "plugin",
    pluginName: "sdlc",
  });
}

/** A main-loop spawn of `type` with `prompt` as its brief, or one inside `parent` when given. */
function spawn($, type: string, prompt = "go", parent?: string) {
  return $.agent.spawn({
    tool_use_id: "toolu_1",
    prompt,
    description: "a task",
    subagentType: type,
    parentModel: "claude-test",
    background: false,
    fork: false,
    ...(parent === undefined ? {} : { parentAgentId: parent }),
  });
}

function turnEnd($, agentId?: string) {
  return $.turn.complete({
    turnId: "t",
    answer: "",
    durationMs: 1,
    isAborted: false,
    reason: "answer",
    usage: null,
    ...(agentId === undefined ? {} : { agentId }),
  });
}

function running(id: string, type: string, parentId?: string): Agent {
  return { id, status: "running", type, ...(parentId === undefined ? {} : { parentId }) };
}

function progressLine(...fields: (string | number)[]) {
  return { exitCode: 0, stdout: `${fields.join(TAB)}\n`, stderr: "" };
}

// --- the line ------------------------------------------------------------------------------------

test("a run in readiness before any brief names a PR reads readiness", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  expect(shown(state)).toBe("readiness");
});

test("a run in the code loop with a reviewer in disprove names the PR, round, stage and counts", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  state.progress = progressLine(1, "code-and-instruction-markdown", "reviewed", "-", "-");
  state.agents = [running("a1", "sdlc:theorem-based-pr-reviewer")];
  await spawn(
    $,
    "sdlc:theorem-based-pr-reviewer",
    `Review ${PR} --mode code-and-instruction-markdown`,
  );
  state.progress = progressLine(2, "code-and-instruction-markdown", "disprove", 15, 31);
  state.agents = [
    running("a1", "sdlc:theorem-based-pr-reviewer"),
    running("c1", "sdlc:theorem-disprover", "a1"),
  ];
  await turnEnd($, "c1");
  expect(shown(state)).toBe(
    "PR #812 · code loop r2 · theorem-based-pr-reviewer › disprove 15/31 theorems",
  );
  const [command, ...args] = state.runs.at(-1) ?? [];
  expect(command.endsWith(PERSIST)).toBe(true);
  expect(args).toEqual(["--mode", "progress", "--pr", PR]);
});

test("generate and assess show the stage alone, and another round's stage is not shown", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  state.agents = [running("a1", "sdlc:theorem-based-pr-reviewer")];
  await spawn($, "sdlc:theorem-based-pr-reviewer", `Review ${PR}`);
  expect(shown(state)).toBe("PR #812 · code loop r1 · theorem-based-pr-reviewer");
  state.progress = progressLine(1, "code-and-instruction-markdown", "assess", 0, 1);
  await turnEnd($, "a1");
  expect(shown(state)).toBe("PR #812 · code loop r1 · theorem-based-pr-reviewer › assess");
  state.progress = progressLine(3, "code-and-instruction-markdown", "generate", 0, 1);
  await turnEnd($, "a1");
  expect(shown(state)).toBe("PR #812 · code loop r1 · theorem-based-pr-reviewer");
});

test("a round under way fixes the reviewer at that round", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  state.progress = progressLine(4, "documentation", "verify", 1, 2);
  state.agents = [running("a1", "sdlc:theorem-based-pr-reviewer")];
  await spawn($, "sdlc:theorem-based-pr-reviewer", `Review ${PR} --mode documentation`);
  expect(shown(state)).toBe(
    "PR #812 · doc loop r4 · theorem-based-pr-reviewer › verify 1/2 theorems",
  );
});

test("a run in monitor shows no round, and with no agent running ends at the phase", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  state.progress = progressLine(2, "code-and-instruction-markdown", "reviewed", "-", "-");
  state.agents = [running("a1", "sdlc:theorem-based-pr-reviewer")];
  await spawn($, "sdlc:theorem-based-pr-reviewer", `Review ${PR}`);
  expect(shown(state)).toBe("PR #812 · code loop r3 · theorem-based-pr-reviewer");
  state.agents = [running("a2", "sdlc:pr-monitor")];
  await spawn($, "sdlc:pr-monitor", `Monitor ${PR}`);
  expect(shown(state)).toBe("PR #812 · monitor · pr-monitor");
  state.agents = [];
  await turnEnd($);
  expect(shown(state)).toBe("PR #812 · monitor");
});

test("an agent completed, failed or killed is not on the line", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  await spawn($, "sdlc:issue-developer");
  await spawn($, "sdlc:issue-developer");
  await spawn($, "sdlc:issue-developer");
  await spawn($, "sdlc:issue-developer");
  state.agents = [
    { id: "a1", status: "completed", type: "sdlc:issue-developer" },
    { id: "a2", status: "failed", type: "sdlc:issue-developer" },
    { id: "a3", status: "killed", type: "sdlc:issue-developer" },
    { id: "a4", status: "idle", type: "sdlc:issue-developer" },
  ];
  await turnEnd($);
  expect(shown(state)).toBe("develop · issue-developer");
});

test("a name running more than once is counted, and children are listed under their parent", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  await spawn($, "sdlc:issue-developer");
  await spawn($, "sdlc:issue-developer");
  await spawn($, "sdlc:pr-merge-readiness", `Gate ${PR}`);
  state.agents = [
    running("a1", "sdlc:issue-developer"),
    running("a2", "sdlc:issue-developer"),
    running("a3", "sdlc:pr-merge-readiness"),
    running("c1", "sdlc:issue-fixer", "a3"),
    running("c2", "sdlc:issue-fixer", "a3"),
    { id: "c3", status: "completed", type: "sdlc:agent-memory-scrubber", parentId: "a3" },
  ];
  await turnEnd($);
  expect(shown(state)).toBe("PR #812 · merge readiness · pr-merge-readiness › issue-fixer×2");
  await spawn($, "sdlc:issue-developer");
  state.agents.push(running("a4", "sdlc:issue-developer"));
  await turnEnd($);
  expect(shown(state)).toBe("develop · issue-developer×3 | #812 merge readiness");
});

test("every other PR with a running agent is appended with its phase", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  await spawn($, "sdlc:docs-writer", `Write ${OTHER_PR}`);
  await spawn($, "sdlc:pr-finalizer", `Finalize ${PR}`);
  state.agents = [running("a1", "sdlc:docs-writer"), running("a2", "sdlc:pr-finalizer")];
  await turnEnd($);
  expect(shown(state)).toBe("PR #812 · finalizer · pr-finalizer | #813 doc loop");
});

test("another PR whose running agent set no phase is appended by its number alone", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  await spawn($, "general-purpose", `Look at ${OTHER_PR}`);
  await spawn($, "sdlc:issue-developer", "Issue #5");
  state.agents = [running("a1", "general-purpose"), running("a2", "sdlc:issue-developer")];
  await turnEnd($);
  expect(shown(state)).toBe("develop · issue-developer | #813");
});

test("the doc loop shows no round of the code loop before its own reviewer runs", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  state.progress = progressLine(2, "code-and-instruction-markdown", "reviewed", "-", "-");
  state.agents = [running("a1", "sdlc:theorem-based-pr-reviewer")];
  await spawn($, "sdlc:theorem-based-pr-reviewer", `Review ${PR}`);
  expect(shown(state)).toBe("PR #812 · code loop r3 · theorem-based-pr-reviewer");
  state.agents = [running("a2", "sdlc:docs-writer")];
  await spawn($, "sdlc:docs-writer", `Write ${PR}`);
  expect(shown(state)).toBe("PR #812 · doc loop · docs-writer");
  state.progress = progressLine(1, "documentation", "generate", 0, 1);
  state.agents = [running("a3", "sdlc:theorem-based-pr-reviewer")];
  await spawn($, "sdlc:theorem-based-pr-reviewer", `Review ${PR} --mode documentation`);
  expect(shown(state)).toBe("PR #812 · doc loop r1 · theorem-based-pr-reviewer › generate");
});

test("a fixer in the same loop keeps the round on the line", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  state.progress = progressLine(2, "code-and-instruction-markdown", "reviewed", "-", "-");
  state.agents = [running("a1", "sdlc:theorem-based-pr-reviewer")];
  await spawn($, "sdlc:theorem-based-pr-reviewer", `Review ${PR}`);
  state.agents = [running("a2", "sdlc:issue-fixer")];
  await spawn($, "sdlc:issue-fixer", `Fix ${PR}`);
  expect(shown(state)).toBe("PR #812 · code loop r3 · issue-fixer");
});

test("a loop's round survives other phases and returns with the loop, and the other loop drops it", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  state.progress = progressLine(2, "code-and-instruction-markdown", "reviewed", "-", "-");
  state.agents = [running("a1", "sdlc:theorem-based-pr-reviewer")];
  await spawn($, "sdlc:theorem-based-pr-reviewer", `Review ${PR}`);
  state.agents = [];
  await spawn($, "sdlc:pr-merge-readiness", `Gate ${PR}`);
  expect(shown(state)).toBe("PR #812 · merge readiness");
  await spawn($, "sdlc:issue-fixer", `Fix ${PR}`);
  expect(shown(state)).toBe("PR #812 · code loop r3");
  state.progress = progressLine(1, "documentation", "reviewed", "-", "-");
  state.agents = [running("a4", "sdlc:theorem-based-pr-reviewer")];
  await spawn($, "sdlc:theorem-based-pr-reviewer", `Review ${PR} --mode documentation`);
  expect(shown(state)).toBe("PR #812 · doc loop r2 · theorem-based-pr-reviewer");
  state.agents = [];
  await spawn($, "sdlc:pr-merge-readiness", `Gate ${PR}`);
  await spawn($, "sdlc:docs-writer", `Write ${PR}`);
  expect(shown(state)).toBe("PR #812 · doc loop r2");
  await spawn($, "sdlc:issue-fixer", `Fix ${PR}`);
  expect(shown(state)).toBe("PR #812 · code loop");
});

test("a reviewer still running from the other loop puts no round on the PR's loop", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  state.progress = progressLine(2, "code-and-instruction-markdown", "reviewed", "-", "-");
  state.agents = [running("a1", "sdlc:theorem-based-pr-reviewer")];
  await spawn($, "sdlc:theorem-based-pr-reviewer", `Review ${PR}`);
  state.agents.push(running("a2", "sdlc:docs-writer"));
  await spawn($, "sdlc:docs-writer", `Write ${PR}`);
  expect(shown(state)).toBe("PR #812 · doc loop · theorem-based-pr-reviewer, docs-writer");
});

// --- the signals ---------------------------------------------------------------------------------

const SPAWNS: [string, string, string][] = [
  ["sdlc:theorem-generator", "Seed issue #5", "seed"],
  ["sdlc:theorem-assessor", "Seed issue #5", "seed"],
  ["sdlc:issue-developer", "Issue #5", "develop"],
  ["sdlc:code-documenter", `Document ${PR}`, "PR #812 · code loop"],
  ["sdlc:issue-fixer", `Fix ${PR}`, "PR #812 · code loop"],
  ["sdlc:style-checker", `Check ${PR} --mode code-and-instruction-markdown`, "PR #812 · code loop"],
  ["sdlc:theorem-based-pr-reviewer", `Review ${PR}`, "PR #812 · code loop"],
  ["sdlc:docs-writer", `Write ${PR}`, "PR #812 · doc loop"],
  ["sdlc:style-checker", `Check ${PR} --mode documentation`, "PR #812 · doc loop"],
  ["sdlc:theorem-based-pr-reviewer", `Review ${PR} --mode documentation`, "PR #812 · doc loop"],
  ["sdlc:agent-memory-scrubber", `Scrub ${PR}`, "PR #812 · memory scrub"],
  ["sdlc:pr-merge-readiness", `Gate ${PR}`, "PR #812 · merge readiness"],
  ["sdlc:pr-finalizer", `Finalize ${PR}`, "PR #812 · finalizer"],
  ["sdlc:pr-monitor", `Monitor ${PR}`, "PR #812 · monitor"],
];

for (const [type, brief, line] of SPAWNS) {
  test(`a main-loop spawn of ${type} briefed "${brief}" reads ${line}`, async ($, on) => {
    const state = host(on);
    await orchestrate($);
    await spawn($, type, brief);
    expect(shown(state)).toBe(line);
  });
}

test("the main loop's read of the plan lib file sets plan, and another read sets nothing", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  await $.tool.call({ tool: "Read", file_path: `${ROOT}/skills/orchestrate/lib/pre-flight.md` });
  expect(shown(state)).toBe("readiness");
  await $.tool.call({ tool: "Read", file_path: `${ROOT}/skills/orchestrate/lib/plan.md` });
  expect(shown(state)).toBe("plan");
});

test("a subagent's read of the plan lib file sets no phase", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  await $.tool.call({
    tool: "Read",
    file_path: `${ROOT}/skills/orchestrate/lib/plan.md`,
    agentId: "a9",
  });
  expect(shown(state)).toBe("readiness");
});

test("a spawn inside another agent sets no phase and names no PR", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  await spawn($, "sdlc:issue-developer");
  await spawn($, "sdlc:pr-monitor", `Monitor ${PR}`, "a1");
  await spawn($, "sdlc:docs-writer", `Write ${PR}`, "a1");
  expect(shown(state)).toBe("develop");
});

test("the cleanup skill sets cleanup, and the main loop's turn ending in it clears the line", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  await spawn($, "sdlc:pr-monitor", `Monitor ${PR}`);
  await cleanup($);
  expect(shown(state)).toBe("PR #812 · cleanup");
  await turnEnd($, "a1");
  expect(shown(state)).toBe("PR #812 · cleanup");
  await turnEnd($);
  expect(shown(state)).toBeUndefined();
  await turnEnd($);
  await spawn($, "sdlc:theorem-based-pr-reviewer", `Review ${PR}`);
  expect(shown(state)).toBeUndefined();
});

test("the phase follows the latest signal, backwards included", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  await spawn($, "sdlc:pr-monitor", `Monitor ${PR}`);
  await spawn($, "sdlc:pr-merge-readiness", `Gate ${PR}`);
  expect(shown(state)).toBe("PR #812 · merge readiness");
});

test("a reviewer spawned with no run under way pins no line", async ($, on) => {
  const state = host(on);
  state.agents = [running("a1", "sdlc:theorem-based-pr-reviewer")];
  await spawn($, "sdlc:theorem-based-pr-reviewer", `Review ${PR}`);
  await turnEnd($, "a1");
  await turnEnd($);
  expect(state.lines).toEqual([]);
  expect(state.runs).toEqual([]);
});

test("a main-loop spawn of another sdlc agent starts a run", async ($, on) => {
  const state = host(on);
  state.agents = [running("a1", "sdlc:issue-fixer")];
  await spawn($, "sdlc:issue-fixer", `Fix ${PR}`);
  expect(shown(state)).toBe("PR #812 · code loop · issue-fixer");
});

test("the orchestrate skill starts a fresh run", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  await spawn($, "sdlc:pr-monitor", `Monitor ${PR}`);
  await orchestrate($);
  expect(shown(state)).toBe("readiness");
});

test("the session's end clears the line", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  await $.session.end({ reason: "other" });
  expect(shown(state)).toBeUndefined();
});

// --- the timer -----------------------------------------------------------------------------------

test("the line is redrawn every 5 seconds while an sdlc agent is running, and not while none is", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  state.agents = [running("a1", "sdlc:issue-developer")];
  await spawn($, "sdlc:issue-developer");
  const drawn = state.lines.length;
  await state.clock.advance(5000);
  expect(state.lines.length).toBe(drawn + 1);
  state.agents = [];
  await state.clock.advance(5000);
  expect(state.lines.length).toBe(drawn + 2);
  await state.clock.advance(20000);
  expect(state.lines.length).toBe(drawn + 2);
});

// --- what the hooks return -----------------------------------------------------------------------

test("every hook but the command's returns what next resolved", async ($, on) => {
  host(on);
  await $.session
    .start({ surface: "terminal", isInteractive: true, cwd: "/work" })
    .then((r) => expect(r).toEqual({ cwd: "/work" }));
  expect(await orchestrate($)).toEqual({ text: "expanded sdlc:orchestrate" });
  expect(
    await $.tool.call({ tool: "Read", file_path: `${ROOT}/skills/orchestrate/lib/plan.md` }),
  ).toEqual({
    result: "contents",
  });
  expect(await spawn($, "sdlc:issue-developer")).toEqual({ model: "claude-test", agentId: "a1" });
  expect(await turnEnd($)).toEqual({ text: "turn stub" });
  expect(await $.session.end({ reason: "other" })).toEqual({ sessionId: "s1" });
});

test("a rejected agent list or progress read leaves each hook's value unchanged", async ($, on) => {
  const state = host(on);
  state.refuseList = "no list";
  expect(await orchestrate($)).toEqual({ text: "expanded sdlc:orchestrate" });
  state.refuseList = undefined;
  state.refuseRun = "cannot start";
  state.agents = [running("a1", "sdlc:theorem-based-pr-reviewer")];
  expect(await spawn($, "sdlc:theorem-based-pr-reviewer", `Review ${PR}`)).toEqual({
    model: "claude-test",
    agentId: "a1",
  });
  expect(await turnEnd($, "a1")).toEqual({ text: "turn stub" });
  expect(shown(state)).toBe("PR #812 · code loop · theorem-based-pr-reviewer");
});

test("a rejected status line leaves the cleanup's turn end and the session's end unchanged", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  await spawn($, "sdlc:pr-monitor", `Monitor ${PR}`);
  await cleanup($);
  state.refuseStatus = "no status";
  expect(await turnEnd($)).toEqual({ text: "turn stub" });
  expect(await $.session.end({ reason: "other" })).toEqual({ sessionId: "s1" });
});

test("a hook whose own work throws logs the error and leaves its value unchanged", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  // A non-string agent type makes the spawn's own handling throw.
  expect(await spawn($, 5 as never, `Fix ${PR}`)).toEqual({ model: "claude-test", agentId: "a1" });
  expect(state.logs.some((line) => line.startsWith(`${COMMAND}: `))).toBe(true);
  expect(await turnEnd($)).toEqual({ text: "turn stub" });
  expect(shown(state)).toBe("PR #812");
});

test("a failed progress read is logged once per run", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  state.progress = { exitCode: 2, stdout: "", stderr: "sdlc-agent-result-persist: boom\n" };
  state.agents = [running("a1", "sdlc:theorem-based-pr-reviewer")];
  await spawn($, "sdlc:theorem-based-pr-reviewer", `Review ${PR}`);
  await turnEnd($, "a1");
  expect(shown(state)).toBe("PR #812 · code loop · theorem-based-pr-reviewer");
  const logged = state.logs.filter((line) => line.includes("boom"));
  expect(logged).toHaveLength(1);
  expect(logged[0]).toContain("exited 2");
});

// --- the error paths, through a hand-built `$` ---------------------------------------------------
//
// The engine drops a `$.ui.log` it cannot deliver rather than throwing, and refuses a value it
// cannot clone, so neither a throwing write nor a thrown value with no text reaches the module
// through `host`. These tests call the hooks `register` registers with a `$` whose every call
// they decide.

/** A thrown value that has no text: `String` of it throws. */
const NO_TEXT_VALUE = Object.create(null);

type Run = { exitCode: number; stdout: string; stderr: string };
type Next = (e: object) => Promise<object>;

/** What the hand-built `$` does on each call, and what it saw the module do. */
type Direct = {
  logs: string[];
  /** Whether `$.ui.log` throws instead of recording its line. */
  isLogBroken: boolean;
  register: () => Promise<void>;
  list: () => Promise<Agent[]>;
  run: () => Promise<Run>;
  status: (text: string | undefined) => void;
  /** The callback of the redraw timer the module started, while one runs. */
  tick?: () => void;
  /** Runs the module's hook on `event` with `e`, its `next` resolving to `result`. */
  hook: (event: string, e: object, result?: object) => Promise<unknown>;
};

function direct(): Direct {
  const hooks = new Map<string, ($: object, e: object, next: Next) => Promise<unknown>>();
  register((event: string, ...rest: unknown[]) => {
    hooks.set(event, rest[rest.length - 1] as never);
  });
  const state: Direct = {
    logs: [],
    isLogBroken: false,
    register: async () => undefined,
    list: async () => [],
    run: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
    status: () => undefined,
    hook: (event, e, result = {}) => {
      const hook = hooks.get(event);
      if (hook === undefined) throw new Error(`no hook on ${event}`);
      return hook($, e, async () => result);
    },
  };
  const $ = {
    plugin: { root: ROOT },
    agent: { list: () => state.list() },
    process: { run: () => state.run() },
    command: { register: () => state.register() },
    clock: {
      every: (ms: number, fn: () => void) => {
        state.tick = fn;
        return { cancel: () => (state.tick = undefined) };
      },
    },
    ui: {
      status: (text: string | undefined) => state.status(text),
      log: (text: string) => {
        if (state.isLogBroken) throw new Error("no log");
        state.logs.push(text);
      },
    },
  };
  return state;
}

/**
 * Starts a run, first ending any earlier test's: these tests share one module instance, and the
 * end stops the timer an earlier run left, so that this run starts its own.
 */
async function directOrchestrate(state: Direct) {
  await state.hook("session.end", {});
  await state.hook("skill.prompt", { skill: "sdlc:orchestrate" });
}

function directReview(state: Direct, id: string) {
  return state.hook(
    "agent.spawn",
    { subagentType: "sdlc:theorem-based-pr-reviewer", prompt: `Review ${PR}` },
    { agentId: id },
  );
}

function failedRead(text: string): () => Promise<Run> {
  return async () => ({ exitCode: 2, stdout: "", stderr: `sdlc-agent-result-persist: ${text}\n` });
}

test("a failed read's line whose write threw is not written in a later run", async () => {
  const state = direct();
  await directOrchestrate(state);
  state.isLogBroken = true;
  state.run = failedRead("first");
  state.list = async () => [running("a1", "sdlc:theorem-based-pr-reviewer")];
  await directReview(state, "a1");
  state.isLogBroken = false;
  await directOrchestrate(state);
  state.run = failedRead("second");
  state.list = async () => [running("a2", "sdlc:theorem-based-pr-reviewer")];
  await directReview(state, "a2");
  await state.hook("turn.complete", {});
  expect(state.logs).toHaveLength(1);
  expect(state.logs[0]).toContain("second");
});

test("a line whose write threw is written ahead of the next line in the same run", async () => {
  const state = direct();
  await directOrchestrate(state);
  state.isLogBroken = true;
  state.run = failedRead("first");
  state.list = async () => [running("a1", "sdlc:theorem-based-pr-reviewer")];
  await directReview(state, "a1");
  state.isLogBroken = false;
  state.list = async () => {
    throw new Error("no list");
  };
  await state.hook("turn.complete", {});
  expect(state.logs).toHaveLength(2);
  expect(state.logs[0]).toContain("first");
  expect(state.logs[1]).toBe(`${COMMAND}: the agent list was not read: no list`);
});

/** A promise and the calls that settle it, for a call a test holds open across a later run. */
function held<T>(): { promise: Promise<T>; resolve: (v: T) => void; reject: (e: unknown) => void } {
  let resolve: (v: T) => void = () => undefined;
  let reject: (e: unknown) => void = () => undefined;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

/** Lets every callback already queued run, so that a held call has been reached. */
function settle() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

test("a progress read that fails once a later run has started writes no line in it", async () => {
  const state = direct();
  await directOrchestrate(state);
  const read = held<Run>();
  state.run = () => read.promise;
  state.list = async () => [running("a1", "sdlc:theorem-based-pr-reviewer")];
  const first = directReview(state, "a1");
  await settle();
  state.list = async () => [];
  await directOrchestrate(state);
  read.reject(new Error("first"));
  await first;
  state.run = failedRead("second");
  state.list = async () => [running("a2", "sdlc:theorem-based-pr-reviewer")];
  await directReview(state, "a2");
  expect(state.logs).toHaveLength(1);
  expect(state.logs[0]).toContain("second");
});

test("a progress read that resolves once a later run has started draws nothing", async () => {
  const state = direct();
  const lines: (string | undefined)[] = [];
  state.status = (text) => void lines.push(text);
  await directOrchestrate(state);
  const read = held<Run>();
  state.run = () => read.promise;
  state.list = async () => [running("a1", "sdlc:theorem-based-pr-reviewer")];
  const first = directReview(state, "a1");
  await settle();
  state.list = async () => [];
  await directOrchestrate(state);
  expect(lines.at(-1)).toBe("readiness");
  read.resolve({ exitCode: 0, stdout: `3${TAB}code${TAB}disprove${TAB}1${TAB}2\n`, stderr: "" });
  await first;
  expect(lines.at(-1)).toBe("readiness");
});

test("an agent list that resolves once a later run has started draws nothing", async () => {
  const state = direct();
  const lines: (string | undefined)[] = [];
  state.status = (text) => void lines.push(text);
  await directOrchestrate(state);
  const list = held<Agent[]>();
  state.list = () => list.promise;
  const first = state.hook(
    "agent.spawn",
    { subagentType: "sdlc:pr-monitor", prompt: `Monitor ${PR}` },
    { agentId: "a1" },
  );
  await settle();
  state.list = async () => [];
  await directOrchestrate(state);
  list.resolve([running("a1", "sdlc:pr-monitor")]);
  await first;
  expect(lines.at(-1)).toBe("readiness");
  expect(state.tick).toBeUndefined();
});

test("a spawn that resolves once a later run has started sets nothing in it", async () => {
  const state = direct();
  const lines: (string | undefined)[] = [];
  state.status = (text) => void lines.push(text);
  await directOrchestrate(state);
  const spawned = held<object>();
  const first = state.hook(
    "agent.spawn",
    { subagentType: "sdlc:pr-monitor", prompt: `Monitor ${PR}` },
    spawned.promise as never,
  );
  await settle();
  await directOrchestrate(state);
  spawned.resolve({ agentId: "a1" });
  await first;
  await state.hook("turn.complete", {});
  expect(lines.at(-1)).toBe("readiness");
});

test("a spawn begun in a run that has since ended starts no run when it resolves", async () => {
  const state = direct();
  const lines: (string | undefined)[] = [];
  state.status = (text) => void lines.push(text);
  await directOrchestrate(state);
  const spawned = held<object>();
  const first = state.hook(
    "agent.spawn",
    { subagentType: "sdlc:pr-monitor", prompt: `Monitor ${PR}` },
    spawned.promise as never,
  );
  await settle();
  await state.hook("session.end", {});
  spawned.resolve({ agentId: "a1" });
  await first;
  await state.hook("turn.complete", {});
  expect(lines.at(-1)).toBeUndefined();
});

test("spawns begun while no run is under way are all recorded, whichever resolves first", async () => {
  const state = direct();
  const lines: (string | undefined)[] = [];
  state.status = (text) => void lines.push(text);
  await state.hook("session.end", {});
  const fixer = held<object>();
  const writer = held<object>();
  const first = state.hook(
    "agent.spawn",
    { subagentType: "sdlc:issue-fixer", prompt: `Fix ${PR}` },
    fixer.promise as never,
  );
  const second = state.hook(
    "agent.spawn",
    { subagentType: "sdlc:docs-writer", prompt: `Write ${OTHER_PR}` },
    writer.promise as never,
  );
  await settle();
  state.list = async () => [running("a1", "sdlc:issue-fixer"), running("a2", "sdlc:docs-writer")];
  writer.resolve({ agentId: "a2" });
  await second;
  fixer.resolve({ agentId: "a1" });
  await first;
  await state.hook("turn.complete", {});
  expect(lines.at(-1)).toBe("PR #812 · code loop · issue-fixer | #813 doc loop");
});

/** A main-loop spawn kind the module treats apart, with no run under way, as its type and brief. */
type Kind = { name: string; type: string; prompt: string };

const OTHER_AGENT: Kind = {
  name: "a non-sdlc agent",
  type: "general-purpose",
  prompt: `Look at ${PR}`,
};
const REVIEW: Kind = {
  name: "the reviewer",
  type: "sdlc:theorem-based-pr-reviewer",
  prompt: `Review ${PR}`,
};
const FIXER: Kind = { name: "an issue-fixer", type: "sdlc:issue-fixer", prompt: `Fix ${PR}` };
const DOCUMENTER: Kind = {
  name: "a code-documenter",
  type: "sdlc:code-documenter",
  prompt: `Document ${PR}`,
};

/**
 * Begins a main-loop spawn of `kind` through the hand-built `$`, and returns the call that
 * resolves it with the agent id `id` and waits for its hook.
 */
function heldSpawn(state: Direct, kind: Kind, id: string): () => Promise<void> {
  const spawned = held<object>();
  const done = state.hook(
    "agent.spawn",
    { subagentType: kind.type, prompt: kind.prompt },
    spawned.promise as never,
  );
  return async () => {
    spawned.resolve({ agentId: id });
    await done;
  };
}

/**
 * Ends any earlier test's run, then records every line the module draws and every progress read
 * it runs from here on.
 */
async function noRun(state: Direct): Promise<{ lines: (string | undefined)[]; reads: number[] }> {
  await state.hook("session.end", {});
  const seen = { lines: [] as (string | undefined)[], reads: [] as number[] };
  state.status = (text) => void seen.lines.push(text);
  state.run = async () => {
    seen.reads.push(1);
    return { exitCode: 0, stdout: "", stderr: "" };
  };
  return seen;
}

// Two spawns overlapping from the no-run state, for one PR, resolved in both orders: the line the
// run draws is the same either way.
const SIBLINGS: [Kind, Kind, string][] = [
  [OTHER_AGENT, FIXER, "PR #812 · code loop · general-purpose, issue-fixer"],
  [REVIEW, FIXER, "PR #812 · code loop r1 · theorem-based-pr-reviewer, issue-fixer"],
  [FIXER, DOCUMENTER, "PR #812 · code loop · issue-fixer, code-documenter"],
];

for (const [one, two, line] of SIBLINGS) {
  for (const [first, second] of [
    [one, two],
    [two, one],
  ]) {
    test(`with no run under way, ${first.name} resolving before ${second.name} draws ${line}`, async () => {
      const state = direct();
      const seen = await noRun(state);
      const resolveOne = heldSpawn(state, one, "a1");
      const resolveTwo = heldSpawn(state, two, "a2");
      await settle();
      state.list = async () => [running("a1", one.type), running("a2", two.type)];
      await (first === one ? resolveOne : resolveTwo)();
      await (first === one ? resolveTwo : resolveOne)();
      await state.hook("turn.complete", {});
      expect(seen.lines.at(-1)).toBe(line);
    });
  }
}

// Two spawns overlapping from the no-run state that neither starts a run: the line stays clear and
// no progress is read, in both orders.
const IDLE_SIBLINGS: [Kind, Kind][] = [
  [OTHER_AGENT, REVIEW],
  [REVIEW, REVIEW],
  [OTHER_AGENT, OTHER_AGENT],
];

for (const [one, two] of IDLE_SIBLINGS) {
  for (const isOneFirst of [true, false]) {
    const [first, second] = isOneFirst ? [one, two] : [two, one];
    test(`with no run under way, ${first.name} resolving before ${second.name} draws no line`, async () => {
      const state = direct();
      const seen = await noRun(state);
      const resolveOne = heldSpawn(state, one, "a1");
      const resolveTwo = heldSpawn(state, two, "a2");
      await settle();
      state.list = async () => [running("a1", one.type), running("a2", two.type)];
      await (isOneFirst ? resolveOne : resolveTwo)();
      await (isOneFirst ? resolveTwo : resolveOne)();
      await state.hook("turn.complete", {});
      expect(seen.lines).toEqual([]);
      expect(seen.reads).toEqual([]);
    });
  }
}

test("a reviewer that resolves before an issue-fixer for another PR is recorded in the fixer's run", async () => {
  const state = direct();
  const seen = await noRun(state);
  const resolveReview = heldSpawn(state, REVIEW, "a1");
  const resolveFixer = heldSpawn(state, { ...FIXER, prompt: `Fix ${OTHER_PR}` }, "a2");
  await settle();
  state.list = async () => [running("a1", REVIEW.type), running("a2", FIXER.type)];
  await resolveReview();
  await resolveFixer();
  expect(seen.lines.at(-1)).toBe("PR #813 · code loop · issue-fixer | #812 code loop");
  state.list = async () => [
    running("a1", REVIEW.type),
    running("a2", FIXER.type),
    running("a3", "sdlc:style-checker"),
  ];
  await state.hook(
    "agent.spawn",
    { subagentType: "sdlc:style-checker", prompt: `Check ${PR}` },
    { agentId: "a3" },
  );
  expect(seen.lines.at(-1)).toBe(
    "PR #812 · code loop r1 · theorem-based-pr-reviewer, style-checker | #813 code loop",
  );
});

// Two spawns begun with no run under way, the first resolving before a run's end or a fresh
// orchestrate prompt and the second after it: nothing either recorded reaches the line a later
// spawn draws, whichever kind resolved first.
const BOUNDARIES: [string, (state: Direct) => Promise<unknown>][] = [
  ["a run's end", (state) => state.hook("session.end", {})],
  [
    "a fresh orchestrate prompt",
    (state) => state.hook("skill.prompt", { skill: "sdlc:orchestrate" }),
  ],
];

for (const [boundary, cross] of BOUNDARIES) {
  for (const [early, late] of [
    [OTHER_AGENT, FIXER],
    [REVIEW, FIXER],
    [FIXER, REVIEW],
    [FIXER, DOCUMENTER],
  ]) {
    test(`${early.name} resolving before ${boundary} and ${late.name} after it reach no line a later spawn draws`, async () => {
      const state = direct();
      const seen = await noRun(state);
      const resolveEarly = heldSpawn(state, early, "a1");
      const resolveLate = heldSpawn(state, late, "a2");
      await settle();
      state.list = async () => [running("a1", early.type), running("a2", late.type)];
      await resolveEarly();
      await cross(state);
      await resolveLate();
      state.list = async () => [
        running("a1", early.type),
        running("a2", late.type),
        running("a3", "sdlc:pr-monitor"),
      ];
      await state.hook(
        "agent.spawn",
        { subagentType: "sdlc:pr-monitor", prompt: `Monitor ${OTHER_PR}` },
        { agentId: "a3" },
      );
      expect(seen.lines.at(-1)).toBe("PR #813 · monitor · pr-monitor");
    });
  }
}

test("spawns that both resolve after a run's end or a fresh orchestrate prompt set nothing", async () => {
  for (const [, cross] of BOUNDARIES) {
    for (const [first, second] of [
      [REVIEW, FIXER],
      [FIXER, REVIEW],
    ]) {
      const state = direct();
      const seen = await noRun(state);
      const resolveFirst = heldSpawn(state, first, "a1");
      const resolveSecond = heldSpawn(state, second, "a2");
      await settle();
      state.list = async () => [running("a1", first.type), running("a2", second.type)];
      await cross(state);
      const atBoundary = seen.lines.at(-1);
      await resolveFirst();
      await resolveSecond();
      await state.hook("turn.complete", {});
      expect(seen.lines.at(-1)).toBe(atBoundary);
      expect(seen.reads).toEqual([]);
    }
  }
});

test("a thrown value with no text is logged as such by every catch", async () => {
  const state = direct();
  state.register = async () => {
    throw NO_TEXT_VALUE;
  };
  await state.hook("session.start", {});
  await directOrchestrate(state);
  const spawned = { agentId: "a1" };
  const unprintableType = {
    startsWith: () => {
      throw NO_TEXT_VALUE;
    },
  };
  const result = await state.hook(
    "agent.spawn",
    { subagentType: unprintableType, prompt: "go" },
    spawned,
  );
  expect(result).toBe(spawned);
  state.list = async () => {
    throw NO_TEXT_VALUE;
  };
  await state.hook("turn.complete", {});
  state.list = async () => [running("a2", "sdlc:theorem-based-pr-reviewer")];
  state.run = async () => {
    throw NO_TEXT_VALUE;
  };
  await directReview(state, "a2");
  expect(state.logs).toEqual([
    `${COMMAND}: the command did not register: ${NO_TEXT}`,
    `${COMMAND}: ${NO_TEXT}`,
    `${COMMAND}: the agent list was not read: ${NO_TEXT}`,
    `${COMMAND}: ${NO_TEXT}`,
  ]);
});

test("a timer redraw that fails with a thrown value with no text logs it rather than rejecting", async () => {
  const state = direct();
  await directOrchestrate(state);
  state.list = async () => [running("a1", "sdlc:issue-developer")];
  await state.hook("agent.spawn", { subagentType: "sdlc:issue-developer", prompt: "go" }, {});
  state.status = () => {
    throw NO_TEXT_VALUE;
  };
  state.tick?.();
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(state.logs).toEqual([`${COMMAND}: the line was not drawn: ${NO_TEXT}`]);
});

// --- the command ---------------------------------------------------------------------------------

test("the session's start registers the command", async ($, on) => {
  const state = host(on);
  await $.session.start({ surface: "terminal", isInteractive: true, cwd: "/work" });
  expect(state.registered).toHaveLength(1);
  expect(state.registered[0]).toMatchObject({
    name: COMMAND,
    argumentHint: "[on|off]",
    immediate: true,
  });
});

test("off clears the line and stops the timer, and on redraws it at the phase reached", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  state.agents = [running("a1", "sdlc:issue-developer")];
  await spawn($, "sdlc:issue-developer");
  const off = await $.command.run({ command: COMMAND, args: "off" });
  expect(off.text).toBe("orchestrate status line: off");
  expect(shown(state)).toBeUndefined();
  const drawn = state.lines.length;
  await state.clock.advance(20000);
  await spawn($, "sdlc:pr-monitor", `Monitor ${PR}`);
  await turnEnd($);
  expect(state.lines.length).toBe(drawn);
  state.agents = [running("a2", "sdlc:pr-monitor")];
  const back = await $.command.run({ command: COMMAND, args: "on" });
  expect(back.text).toBe("orchestrate status line: on");
  expect(shown(state)).toBe("PR #812 · monitor · pr-monitor");
});

test("off runs no progress read", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  await $.command.run({ command: COMMAND, args: "off" });
  state.agents = [running("a1", "sdlc:theorem-based-pr-reviewer")];
  await spawn($, "sdlc:theorem-based-pr-reviewer", `Review ${PR}`);
  await turnEnd($, "a1");
  expect(state.runs).toEqual([]);
});

test("no argument flips the line, and any other argument answers the usage and changes nothing", async ($, on) => {
  const state = host(on);
  await orchestrate($);
  expect((await $.command.run({ command: COMMAND, args: "" })).text).toBe(
    "orchestrate status line: off",
  );
  expect(shown(state)).toBeUndefined();
  expect((await $.command.run({ command: COMMAND, args: "maybe" })).text).toBe(USAGE);
  await turnEnd($);
  expect(shown(state)).toBeUndefined();
  expect((await $.command.run({ command: COMMAND, args: "" })).text).toBe(
    "orchestrate status line: on",
  );
  expect(shown(state)).toBe("readiness");
  expect((await $.command.run({ command: COMMAND, args: "off on" })).text).toBe(USAGE);
  expect(shown(state)).toBe("readiness");
});
