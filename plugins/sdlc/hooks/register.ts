// The plugin's one hooks module: the engine refuses a `hooks.json` whose `modules` holds more than
// one path, so this module registers the hooks the other modules in this directory define.

import { register as registerOrchestrateStatus } from "./orchestrate-status.ts";
import { register as registerReloadAfterCompact } from "./reload-after-compact.ts";

type On = Parameters<typeof registerReloadAfterCompact>[0];

/** Registers the hooks of `reload-after-compact.ts`, then those of `orchestrate-status.ts`. */
export function register(on: On): void {
  registerReloadAfterCompact(on);
  registerOrchestrateStatus(on);
}
