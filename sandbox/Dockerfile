FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
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
COPY --chown=ubuntu:ubuntu config_context/.vimrc /home/ubuntu/.vimrc

USER ubuntu
ENV PATH="/home/ubuntu/.cargo/bin:/home/ubuntu/.local/bin:${PATH}"

RUN curl -LsSf https://astral.sh/uv/install.sh | sh

RUN uv python install

RUN uv tool install ipython

RUN curl -fsSL https://claude.ai/install.sh | bash

RUN curl https://sh.rustup.rs -sSf | sh -s -- -y && rustup component add rustfmt

USER root

RUN ssh-keyscan github.com >> /etc/ssh/ssh_known_hosts 2>/dev/null; \
    chmod 644 /etc/ssh/ssh_known_hosts

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
