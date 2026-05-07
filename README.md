# claude-box

Run Claude Code in a Docker sandbox with `--dangerously-skip-permissions` — no macOS approval prompts, no risk to your host system.

Designed as a drop-in replacement for running Claude Code locally: full interactive TTY, persistent state across sessions, all your skills and plugins available inside the container.

## Why

Claude Code's permission system is great for cautious use but creates friction for autonomous/faff-skill runs. Running inside Docker gives you the bypass without compromising your host — the container can't escape the bind-mounted directories.

## How it works

- Project dir is bind-mounted at its **exact host path** so skill symlinks resolve correctly
- `~/.claude-box/state/` persists Claude Code state (settings, conversation history) across runs — delete to reset
- `~/.claude` skills, plugins, hooks, and `.mcp.json` are bind-mounted read-only so your local setup is always reflected
- Symlinked skills (pointing outside `~/.claude/`) have their parent dirs auto-mounted
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
cd ~/claude-box && git pull
```

The image rebuilds automatically on the next run when the Dockerfile changes.
