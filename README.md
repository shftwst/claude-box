# claude-box

A Docker sandbox for Claude Code that feels native. Your global skills, plugins, MCP servers, git config, and persistent Claude sessions all carry over — with per-project overrides via a simple `.env.claude-box` file.

## Why

Plenty of options already run Claude Code in a sandbox — Docker's built-in sandbox mode, generic containers, dev containers. The harder problem is making that sandbox feel like running Claude natively: every `~/.claude/` skill resolved (including symlinks pointing into other repos), MCP servers reachable, `.gitconfig` and SSH agent forwarded, macOS Keychain credentials still valid, sessions resumable across container and host.

claude-box bridges that gap. It wires up the bind-mounts, credential extraction, and env forwarding so you get the `--dangerously-skip-permissions` bypass without giving up the native ergonomics. And `.env.claude-box` lets each project layer its own forwarded env vars and extra mounts on top — no global config edits, no remembering which API key belongs to which workspace.

## How it works

- Project dir is bind-mounted at its **exact host path** so skill symlinks resolve correctly
- `~/.claude-box/state/` persists Claude Code state (settings, conversation history) across runs — delete to reset
- `~/.claude` skills, plugins, hooks, and `.mcp.json` are bind-mounted read-only so your local setup is always reflected
- Symlinked skills (pointing outside `~/.claude/`) have their parent dirs auto-mounted
- Sessions for the current project are written back to `~/.claude/projects/<slug>/` on the host, so a conversation started in claude-box is resumable from host Claude — and vice versa. Session-keyed satellite state (todos, plan-mode drafts, file-edit history) is shared too
- macOS Keychain credentials are extracted at launch and written to the state dir
- `settings.json` is synced on first run (stripping sandbox/hooks, rewriting macOS-specific paths)

## Requirements

- Docker Desktop (or Docker Engine on Linux)
- Node.js (for the settings sync script — just needs `node` in PATH)
- macOS or Linux

## Installation

```bash
git clone https://github.com/shftwst/claude-box ~/claude-box
ln -sf ~/claude-box/claude-box /usr/local/bin/claude-box
chmod +x ~/claude-box/claude-box
```

The image builds automatically on first run (and rebuilds when the Dockerfile changes).

## Usage

```bash
claude-box                  # interactive session in current directory
claude-box /path/to/dir     # interactive session in another directory
claude-box . -c             # continue most recent session
claude-box . --resume       # pick a session to resume (interactive picker)
claude-box . -r <id>        # resume a specific session by ID
claude-box . -p "..."       # non-interactive prompt (pipe-friendly)
```

All arguments after the first (directory) are passed directly to `claude`.

### claude-box flags

These are consumed by the wrapper before `claude` sees them (position-free, so they can appear anywhere on the command line):

- `--upgrade` — `git pull` the install dir and exit. See [Updating](#updating).
- `--no-ssh` — skip mounting `~/.ssh` and forwarding the SSH agent. Disables git-over-SSH and commit signing inside the container; useful for sessions that don't touch git remotes.

## Extra env vars

The default forwarded vars are: `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `GITHUB_PERSONAL_ACCESS_TOKEN`, `LINEAR_API_KEY`.

To forward additional vars without modifying the script:

```bash
CLAUDE_BOX_EXTRA_VARS=(TURSO_AUTH_TOKEN MY_API_KEY) claude-box
```

Or set it in your shell profile:

```bash
export CLAUDE_BOX_EXTRA_VARS=(TURSO_AUTH_TOKEN NETLIFY_AUTH_TOKEN)
```

### Per-project values via `.env.claude-box`

Drop a `.env.claude-box` file in a project root to supply project-specific values for any of the forwarded vars. It's sourced just before the env lookup, so values here override whatever's in your shell — useful when each project is backed by a different API key (e.g. different `LINEAR_API_KEY` per workspace).

```bash
# .env.claude-box (in your project root, gitignored)
LINEAR_API_KEY=lin_proj_specific_xxx
TURSO_AUTH_TOKEN=ey...
```

Plain `KEY=value` lines work — no `export` needed. Add `.env.claude-box` to `.gitignore` (or rely on your global `.env.*` ignore) since it holds secrets.

## Extra mounts

By default the container sees: the project dir, `~/.ssh` (read-only), `~/.claude` skills/plugins/hooks/`.mcp.json` (read-only), and the Docker socket. To expose additional host paths inside the container, set `CLAUDE_BOX_EXTRA_MOUNTS` to an array of `host:container[:opts]` specs:

```bash
CLAUDE_BOX_EXTRA_MOUNTS=("$HOME/.aws:$HOME/.aws:ro" "/data:/data") claude-box
```

Or per-project in `.env.claude-box`:

```bash
# .env.claude-box
CLAUDE_BOX_EXTRA_MOUNTS=("$HOME/.config/gcloud:$HOME/.config/gcloud:ro")
```

Each entry is passed straight to `docker run -v`, so the standard `:ro` / `:rw` / propagation suffixes all work. Use this when a project needs cloud credentials, a shared dataset, or any other host directory that isn't part of the default mount set.

## State

State lives in `~/.claude-box/state/` — this is the `~/.claude` directory as seen by Claude Code inside the container. Conversation history, project memories, and settings persist here across runs.

To reset completely:

```bash
rm -rf ~/.claude-box/state/
```

## Updating

```bash
claude-box --upgrade
```

This runs `git pull --ff-only` on the install dir and exits. The image rebuilds automatically on the next regular run when the Dockerfile or entrypoint changed.

On startup, claude-box does a backgrounded `git fetch` against the install dir at most once every 24 hours. When the check finds you're behind upstream, the next launch prints a single hint line:

```
[claude-box] update available — run 'claude-box --upgrade' to pull latest
```

The check runs detached and adds no perceptible latency to launch; the hint disappears the next time `--upgrade` succeeds.
