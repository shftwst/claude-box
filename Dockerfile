FROM node:22-bookworm-slim

# System deps + GitHub CLI + Docker CLI (for GitHub MCP server)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates gnupg unzip jq \
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

# Claude Code
RUN npm install -g @anthropic-ai/claude-code

COPY entrypoint.sh /usr/local/bin/claude-box-entrypoint.sh
RUN chmod +x /usr/local/bin/claude-box-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/claude-box-entrypoint.sh"]
