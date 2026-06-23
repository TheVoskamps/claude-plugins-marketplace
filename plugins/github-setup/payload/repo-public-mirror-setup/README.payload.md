# `repo-public-mirror-setup` payload

Template payload for the `repo-public-mirror-setup` skill. The skill
reads these files from
`${CLAUDE_PLUGIN_ROOT}/payload/repo-public-mirror-setup/`, renders the
placeholders below, and installs the rendered output into the target
(source) repo. See the github-setup plugin payload README for the
placeholder/render/existence-check contract this directory conforms to.

This file (`README.payload.md`) is documentation for maintainers — it
is NOT installed into the target repo and carries no placeholders. It
is named `README.payload.md` so it does not collide with `README.md`,
which IS an installed template (the mirror's read-only banner).

## Placeholders

| Placeholder | Meaning | Resolution |
| --- | --- | --- |
| `__GH_ORG__` | GitHub org/user that owns the source repo | inferred: `gh repo view --json owner -q .owner.login` |
| `__GH_REPO__` | Source repo short name; also the mirror name (`__GH_REPO__-public`) and the `__GH_REPO__.local` mailmap domain | inferred: `gh repo view --json name -q .name` |
| `__GH_OWNER_NAME__` | Human owner name embedded in the `PATENTS` / `PRIOR_ART.md` prior-art notice | prompted from the user |
| `__RELEASE_DATE__` | Public-release date in the `PATENTS` / `PRIOR_ART.md` prior-art notice | prompted from the user |

## Files and where they install

| Template file | Installs to (in the source repo) | Notes |
| --- | --- | --- |
| `paths.allowlist` | `.github/public-mirror/paths.allowlist` | Starter; user fills the repo-specific section at Halt #2. |
| `mailmap` | `.github/public-mirror/mailmap` | Header-only; skill seeds author entries from `git log`. |
| `gitignore.mirror` | `.github/public-mirror/gitignore.mirror` | Mirror's root `.gitignore`, renamed in via `paths.allowlist`. |
| `replacements.txt` | `.github/public-mirror/replacements.txt` | Starter; rules are repo-specific, empty by default. |
| `public-mirror.yml` | `.github/workflows/public-mirror.yml` | The filter+push workflow. |
| `CONTRIBUTORS.template` | `CONTRIBUTORS` (repo root) | Static informational file shipped to the mirror. |
| `LICENSE` | bootstrap commit (Step 12) if the source lacks one | GPL v3 verbatim; no placeholders. |
| `PATENTS` | bootstrap commit (Step 12) if the source lacks one | Prior-art notice. |
| `PRIOR_ART.md` | bootstrap commit (Step 12) if the source lacks one | Prior-art notice. |
| `README.md` | bootstrap commit (Step 12) — mirror's read-only banner | Public-facing landing page. |

The `LICENSE`, `PATENTS`, `PRIOR_ART.md`, and `README.md` starters are
only written into the mirror when the source repo does not already
provide its own — the workflow publishes whatever the source repo's
allowlisted paths contain on every run.
