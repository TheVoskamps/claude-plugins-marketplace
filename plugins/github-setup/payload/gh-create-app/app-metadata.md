<!--
Template for /gh-create-app. Rendered into the target repo at
docs/github-app.md (or a path the user picks).

Placeholders (see the github-setup plugin payload README for the convention):
  __APP_NAME__            GitHub App slug (e.g. thevoskamps-pr-bot)
  __APP_ID__              numeric App ID
  __APP_OWNER__           org or enterprise that owns the App
  __APP_SCOPE__           "organization" or "enterprise"
  __APP_INSTALL_URL__     install/settings URL for the App
  __APP_PERMISSIONS__     rendered list of granted permissions
  __APP_ID_SECRET__       repo/org secret holding the App ID
  __APP_PRIVATE_KEY_SECRET__  repo/org secret holding the private key
  __SECRET_SCOPE__        "repository" or "organization"
  __CREATED_DATE__        ISO date the App was registered/recorded

This comment block is stripped at render time; only the body below is
written to the target repo.
-->
# GitHub App: `__APP_NAME__`

This repo authenticates selected GitHub Actions workflows as the
GitHub App **`__APP_NAME__`** rather than the default `GITHUB_TOKEN`.
A short-lived installation token is minted per workflow run from the
App ID and private key stored in secrets; there is no long-lived token
to rotate manually.

This document is the checked-in record of that App. It is maintained
by the `/gh-create-app` skill — re-run the skill to verify or update
it.

## Identity

| Field | Value |
| --- | --- |
| App name (slug) | `__APP_NAME__` |
| App ID | `__APP_ID__` |
| Owner | `__APP_OWNER__` |
| Scope | `__APP_SCOPE__` |
| Settings / install URL | `__APP_INSTALL_URL__` |
| Recorded | `__CREATED_DATE__` |

## Granted permissions

The App was registered with these repository permissions:
`__APP_PERMISSIONS__`.

No webhook is configured: this App is used only for minting
installation tokens in CI, not for receiving event deliveries.

## Secrets

The App ID and private key are stored as `__SECRET_SCOPE__` secrets:

| Secret | Holds |
| --- | --- |
| `__APP_ID_SECRET__` | the numeric App ID (`__APP_ID__`) |
| `__APP_PRIVATE_KEY_SECRET__` | the App's PEM private key |

The private key is never committed to the repo and never printed to
logs. To rotate it, generate a new private key in the App's settings,
update the `__APP_PRIVATE_KEY_SECRET__` secret, then delete the old
key in the App settings.

## Using the App in a workflow

Mint an installation token at the start of the job and pass it to
downstream steps. See `.github/workflows/` for the live usage; the
canonical snippet is:

```yaml
    steps:
      - name: Mint App installation token
        id: app-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        with:
          app-id: ${{ secrets.__APP_ID_SECRET__ }}
          private-key: ${{ secrets.__APP_PRIVATE_KEY_SECRET__ }}
      - name: Do privileged work as the App
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
        run: gh api /repos/${{ github.repository }} --jq .full_name
```

The minted token authorises only the permissions granted to the App
above, and expires within the hour. The `permissions:` block of the
workflow governs the default `GITHUB_TOKEN` only; it does not affect
the App installation token.
