FROM node:22-bookworm-slim

# System deps + GitHub CLI + Docker CLI (for GitHub MCP server)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates gnupg unzip jq openssh-client socat \
    python3 python3-pip python3-venv \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       | tee /etc/apt/sources.list.d/github-cli.list \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
       | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bookworm stable" \
       | tee /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y gh docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# Chromium runtime libs so Playwright (installed per-project in venvs) can launch
# its bundled browser without needing root at runtime. Browser binary itself is
# not baked in — `playwright install chromium` fetches it on demand.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libnss3 libnspr4 libdbus-1-3 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2 \
    libpango-1.0-0 libcairo2 libxkbcommon0 \
    && rm -rf /var/lib/apt/lists/*

# uv — fast Python package + venv manager. Used by skills that bootstrap Python
# deps without polluting system site-packages or hitting PEP 668. Pulled from
# the official Astral image so we don't curl-pipe-sh.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Bun (required for Claude Code plugins — claude-hud, etc.)
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash

# Yarn Berry (for Node.js projects using Yarn 4)
RUN corepack enable && corepack prepare yarn@4.13.0 --activate

# gosu — minimal su/sudo for Docker; does a direct exec as the target user
# so the TTY and signal handling are properly inherited (unlike su -c "...").
RUN curl -fsSL "https://github.com/tianon/gosu/releases/download/1.17/gosu-$(dpkg --print-architecture)" \
       -o /usr/local/bin/gosu \
    && chmod +x /usr/local/bin/gosu \
    && gosu nobody true

# ugrep + shadow grep with it. Claude Code on the host transparently redirects
# `grep` to ugrep (via a shell function) so patterns can use ugrep extensions
# like `\t` in -E regex. Subprocesses spawned by Claude Code (e.g. statusLine
# commands from plugins like claude-hud) don't inherit that shell function, so
# in the container we install ugrep system-wide and put a `grep` symlink on
# /usr/local/bin (which precedes /usr/bin on PATH) — anything resolving `grep`
# via PATH gets ugrep, while scripts that hardcode /usr/bin/grep still hit the
# stock GNU grep.
RUN apt-get update && apt-get install -y --no-install-recommends ugrep \
    && ln -sf /usr/bin/ugrep /usr/local/bin/grep \
    && rm -rf /var/lib/apt/lists/*

# Claude Code
RUN npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force

COPY entrypoint.sh /usr/local/bin/claude-box-entrypoint.sh
RUN chmod +x /usr/local/bin/claude-box-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/claude-box-entrypoint.sh"]
