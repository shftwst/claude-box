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
- A **nested container engine** runs inside the box (rootless dockerd by default), so `docker` / `docker compose` work in-session without ever exposing the host's docker socket

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

`claude-box` always runs in the current directory (the project root) — `cd` into your project first.

```bash
claude-box                  # interactive session
claude-box -c               # continue most recent session
claude-box --resume         # pick a session to resume (interactive picker)
claude-box -r <id>          # resume a specific session by ID
claude-box -p "..."         # non-interactive prompt (pipe-friendly)
```

Every argument is passed directly to `claude`. Use `--` to force everything after it to `claude`, so a `claude` flag that shares a name with a claude-box flag can still be passed (e.g. `claude-box -- --engine foo`).

### claude-box flags

These are consumed by the wrapper before `claude` sees them (position-free, so they can appear anywhere on the command line):

- `--upgrade` — `git pull` the install dir and exit. See [Updating](#updating).
- `--no-ssh` — skip mounting `~/.ssh` and forwarding the SSH agent. Disables git-over-SSH and commit signing inside the container; useful for sessions that don't touch git remotes.
- `--ollama <model>` — point Claude Code at an Ollama server instead of the Anthropic API. See [Ollama](#ollama).
- `--engine <mode>` — nested container engine posture: `auto` (default), `sysbox`, `rootless`, `privileged-dind`, `none`. See [Nested container engine](#nested-container-engine).

## Ollama

Run Claude Code against a local (or remote) Ollama server that exposes the Anthropic-compatible API, mirroring `ollama launch claude --model <model>`:

```bash
claude-box --ollama qwen3-coder:30b-a3b-q4_K_M
claude-box --ollama qwen3-coder:30b-a3b-q4_K_M -c   # combine with other flags
```

The flag is a command-line override — nothing is baked into `.env.claude-box` — and wires up, inside the container:

- `ANTHROPIC_BASE_URL` from `OLLAMA_HOST` (adding `http://` if the scheme is missing), falling back to `http://localhost:11434`
- `ANTHROPIC_AUTH_TOKEN=ollama` (a dummy token Ollama ignores but Claude Code requires)
- `ANTHROPIC_MODEL` and `ANTHROPIC_SMALL_FAST_MODEL` both set to the model you pass

Because the base URL follows `OLLAMA_HOST`, pointing it at a **Tailscale peer** just works — set `OLLAMA_HOST=100.x.y.z:11434` (as your `ollama` CLI already does) and the container reaches it over the normal bridge network. No `--network host` is needed: a container can already route to any address the host can reach, including the tailnet.

## Nested container engine

The box ships its own container engine *inside* the cage: `docker` and `docker compose` work in-session, but their authority is bounded by the cage. The host's docker socket is **never** mounted — the entrypoint refuses to start if one is present, because a host socket is root-equivalent control of the host and would void the sandbox entirely.

Container engines, selected with `--engine` (or `CLAUDE_BOX_ENGINE_MODE` in `.env.claude-box`):

- `auto` (default) — `sysbox` if the host docker has the sysbox-runc runtime, else `rootless`.
- `sysbox` — rootful dockerd inside a [sysbox](https://github.com/nestybox/sysbox) container. Strongest posture; requires sysbox installed on the host/VM.
- `rootless` — rootless dockerd (rootlesskit) running as the unprivileged in-box user. The cage stays non-privileged; the relaxations it needs are `seccomp=unconfined` + `systempaths=unconfined` (rootlesskit must create user namespaces and write `net.ipv4.ip_forward` in its own detached netns), the `/dev/net/tun` + `/dev/fuse` devices, and on apparmor hosts either `apparmor=unconfined` or a tiny `claude-box-engine` profile granting the `userns` permission.
- `privileged-dind` — rootful dockerd in a `--privileged` cage. This is the weakest option and therefore is explicit opt-in only, the launcher warns, and it should be a last resort.
- `none` — no engine.

On first launch (per docker host) the `rootless` posture probes for the weakest working relaxation set and caches it in `~/.claude-box/.userns-strategy-*`:

- `plain` — the relaxations above suffice (typical for Docker Desktop / OrbStack).
- `profile` / `profile-cap` — Ubuntu-lineage kernels (Colima VMs, Ubuntu 23.10+) restrict unprivileged user namespaces via apparmor; the launcher loads the `claude-box-engine` apparmor profile into the VM kernel through a privileged one-shot helper (host-altitude setup by the human-run wrapper — the cage itself never gets that authority), and `profile-cap` additionally adds `CAP_SYS_ADMIN` to the cage's *bounding* set, which the kernel demands for the setuid `newuidmap` helpers there. The cap is latent: unprivileged in-box processes only reach it through those helpers.
- `cap` — `CAP_SYS_ADMIN` alone (restricted kernel without apparmor mediation).

Delete `~/.claude-box/.userns-strategy-*` to force a re-probe (e.g. after changing docker runtimes).

Engine storage is an anonymous volume, removed when the session ends — nested images don't persist across sessions. To keep a warm image cache, mount a named volume at the engine's data root (one box at a time — concurrent daemons on one data root won't start):

```bash
CLAUDE_BOX_EXTRA_MOUNTS=("claude-box-engine-cache:/var/lib/claude-box-engine") claude-box
```

Verification: run the four checks in [docs/cage-engine-acceptance.md](docs/cage-engine-acceptance.md) inside the box. Expect `docker info --format '{{.SecurityOptions}}'` to contain `name=rootless` under the default posture, and `/var/run/docker.sock` to be absent (rootless) or owned by the nested daemon (rootful).

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

### Cloud CLI auth

The image bundles several deploy/cloud CLIs (`aws`, `flyctl`, `netlify`, `wrangler`, `gh`). Each authenticates non-interactively from a **precise** env var name — forward the ones you need via `CLAUDE_BOX_EXTRA_VARS` (or set them per-project in `.env.claude-box`). The names are load-bearing; the launcher forwards them verbatim, so don't rename them.

| CLI | Env var(s) | Notes |
| --- | --- | --- |
| `aws` (AWS CLI v2) | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Session token only for temporary creds. `AWS_DEFAULT_REGION` (or `AWS_REGION`) sets the region; `AWS_PROFILE` selects a named profile. |
| `flyctl` (Fly.io) | `FLY_API_TOKEN` | From `flyctl auth token`. `FLY_ACCESS_TOKEN` is also honored. |
| `netlify` | `NETLIFY_AUTH_TOKEN` | Personal access token. `NETLIFY_SITE_ID` targets a site without a linked repo. |
| `wrangler` (Cloudflare) | `CLOUDFLARE_API_TOKEN` | Add `CLOUDFLARE_ACCOUNT_ID` when the token spans multiple accounts. Legacy `CLOUDFLARE_API_KEY` + `CLOUDFLARE_EMAIL` global-key auth also works but prefer a scoped token. |
| `gh` (GitHub) | `GH_TOKEN` or `GITHUB_TOKEN` | `GITHUB_TOKEN` / `GITHUB_PERSONAL_ACCESS_TOKEN` are already in the default forwarded set. |

Example — forward AWS and Cloudflare creds for a project:

```bash
# .env.claude-box
CLAUDE_BOX_EXTRA_VARS=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID)
```

> **Heads up:** `flyctl` and `wrangler` also fall back to on-disk config (`~/.fly/`, `~/.wrangler/` or `~/.config/.wrangler/`) when the env var is absent. Those paths aren't in the default mount set, so nothing leaks in unless you mount them explicitly — prefer forwarding a scoped token over mounting host credential dirs.

## Extra mounts

By default the container sees: the project dir, `~/.ssh` (read-only), and `~/.claude` skills/plugins/hooks/`.mcp.json` (read-only) — never the host docker socket (a mount at `/var/run/docker.sock` makes the box refuse to start). To expose additional host paths inside the container, set `CLAUDE_BOX_EXTRA_MOUNTS` to an array of `host:container[:opts]` specs:

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
