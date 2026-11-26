# github-claude-identity

Runs `git` and `gh` against GitHub as Claude's own bot identity, a
dedicated GitHub App account, instead of as you.

## Why you would want it

Without it, everything Claude Code does on GitHub carries your name:
its commits, pushes, PRs and issue comments are indistinguishable from
the ones you made by hand. With it, that work is attributed to
`<app-slug>[bot]`, with GitHub's bot badge, so history and review
threads show who did what.

The bot is also a narrower credential than you are. It acts through a
GitHub App that holds only the permissions you grant it and is
installed only on the repositories you pick, and it authenticates with
installation tokens that GitHub expires within the hour.

Your own setup stays as it is. `~/.gitconfig` is never touched, and the
bot identity applies per repository or per command, so your personal
repositories and your own commits are unaffected.

## What you need first

- A GitHub account or organization where you may register a GitHub App
  and install it on the repositories Claude works in. GitHub allows App
  registration only through its web UI, so this part is done by hand.
- `gh`, authenticated as yourself, and `git`.
- `bash`, `jq`, `openssl` and `curl`, which mint the bot's tokens.
- A git repository to run the setup from.

## Getting started

Run the setup skill once per machine, from inside a repository the bot
should work in:

```text
/gh-create-identity-app
```

A typical run:

1. It shows the plan it resolved: the App name, the owner, the config
   directory and the repository.
2. It walks you through registering the App in GitHub's web UI and
   waits while you do it. You hand back the App ID, the App slug and
   the path to the private key file GitHub downloaded. You give the
   path only; the key's contents never enter the conversation.
3. It waits again while you install the App on your repositories, then
   takes the installation ID.
4. It sets up `~/.config/claude-github-app/`: the helper scripts, your
   private key, and a config rendered from your App's identifiers. It
   then mints a token to prove those line up.
5. It points the repository at the bot: a local `user.name` and
   `user.email`, a credential helper, and an HTTPS origin in place of
   an SSH one.
6. It verifies that `gh_wrapper` reports the bot's login. With your
   go-ahead it also makes a trial commit, so you can see the badge on
   GitHub.
7. It offers to add a rule include to your `CLAUDE.md`, and makes that
   edit only if you approve it.

Running the skill again is safe. It detects what is already in place
and converges on it, so it never registers a second App by accident.

Day to day, the plugin puts two commands on `PATH`:

- `gh_wrapper` takes the arguments `gh` takes and runs it under a
  freshly minted bot token.
- `git_wrapper` takes the arguments `git` takes and runs it with the
  bot's name, email and credential helper for that one invocation. It
  writes no git config, so it works in a repository that was never set
  up.

```bash
gh_wrapper pr create --fill
git_wrapper push
```

In a repository the skill has set up, plain `git commit` and `git push`
already act as the bot. To set up another repository, run
`~/.config/claude-github-app/init-repo.sh` inside it.

## What it deliberately does not do

- **It does not provision an App for CI.** This identity is for Claude
  working on your machine. A workflow that needs its own App
  credentials is a separate concern with a separate App.
- **It does not register the App for you.** GitHub gates registration
  behind its web UI, and the skill never tries to go around that.
- **It does not put a secret in a repository.** The private key, the
  rendered config and the token cache live only in
  `~/.config/claude-github-app/`. The plugin itself ships no secret.
- **It does not store the private key in the macOS Keychain.** The key
  is a file readable only by you; disk encryption is the protection it
  assumes.
- **It does not wire the credential helper globally.** A global helper
  would make your personal repositories authenticate as the bot, so
  the wiring is per repository.
- **It does not stop plain `gh` from running as you.** The plugin ships
  no hook. In a set-up repository `git` acts as the bot, but `gh` does
  so only when called as `gh_wrapper`.
- **It does not fail when the identity is missing.** On a machine with
  no setup, both wrappers run plain `gh` and `git` as you, without a
  warning.
- **It does not authenticate over SSH as the bot.** Git ignores a
  credential helper on an SSH remote, so there `git_wrapper` sets the
  bot's name and email but pushes with your SSH key. The setup's HTTPS
  origin switch is what avoids this.
