FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    bat \
    build-essential \
    curl \
    dnsutils \
    eza \
    fzf \
    git \
    gnuplot \
    iproute2 \
    iputils-ping \
    jq \
    libzstd-dev \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    sharutils \
    sudo \
    tmux \
    unzip \
    vim-nox \
    wget \
    xdg-utils \
    zoxide \
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

COPY --chown=ubuntu:ubuntu config_context/.zshrc /home/ubuntu/.zshrc
COPY --chown=ubuntu:ubuntu config_context/.vimrc /home/ubuntu/.vimrc

USER ubuntu
ENV PATH="/home/ubuntu/.cargo/bin:/home/ubuntu/.local/bin:${PATH}"

RUN curl -LsSf https://astral.sh/uv/install.sh | sh

RUN uv python install

RUN uv tool install ipython

RUN curl -fsSL https://claude.ai/install.sh | bash

RUN mkdir -p /home/ubuntu/.ssh && \
    ssh-keyscan github.com >> /home/ubuntu/.ssh/known_hosts 2>/dev/null && \
    chmod 700 /home/ubuntu/.ssh && chmod 644 /home/ubuntu/.ssh/known_hosts

RUN curl https://sh.rustup.rs -sSf | sh -s -- -y && rustup component add rustfmt

USER root

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
