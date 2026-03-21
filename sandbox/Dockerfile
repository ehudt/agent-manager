FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    bubblewrap \
    build-essential \
    curl \
    dnsutils \
    git \
    iproute2 \
    iputils-ping \
    jq \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    sudo \
    unzip \
    vim-nox \
    wget \
    zsh \
    zstd \
    && rm -rf /var/lib/apt/lists/*

# Set default shell for the ubuntu user
RUN chsh -s /bin/zsh ubuntu

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Preinstall Playwright runtime dependencies and Chromium for UI tests.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npx -y playwright install-deps chromium && \
    npx -y playwright install chromium && \
    chmod -R 755 /ms-playwright

RUN npm install -g @openai/codex

COPY config_context/.zshrc /etc/zsh/zshrc
COPY config_context/.vimrc /etc/skel/.vimrc

# Install uv to /usr/local/bin so it survives a bind-mount over /home/ubuntu
ENV UV_INSTALL_DIR=/usr/local/bin
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Install Claude CLI: install as ubuntu, then copy binary to system path
USER ubuntu
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root
RUN cp "$(readlink -f /home/ubuntu/.local/bin/claude)" /usr/local/bin/claude && \
    rm -rf /home/ubuntu/.local/share/claude /home/ubuntu/.local/bin/claude /home/ubuntu/.claude

RUN ssh-keyscan github.com >> /etc/ssh/ssh_known_hosts 2>/dev/null; \
    chmod 644 /etc/ssh/ssh_known_hosts

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
