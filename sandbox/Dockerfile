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

# Rename the default ubuntu user to dev
RUN usermod -l dev ubuntu && \
    groupmod -n dev ubuntu && \
    usermod -d /home/dev -m dev && \
    chsh -s /bin/zsh dev

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Preinstall Playwright runtime dependencies and Chromium for UI tests.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npx -y playwright install-deps chromium && \
    npx -y playwright install chromium && \
    chmod -R 755 /ms-playwright

RUN npm install -g @openai/codex

# Config defaults restored by entrypoint on first boot
RUN mkdir -p /opt/dev_config
COPY config_context/.zshrc /opt/dev_config/.zshrc
COPY config_context/.vimrc /opt/dev_config/.vimrc

USER dev

RUN curl -LsSf https://astral.sh/uv/install.sh | sh

RUN uv python install

RUN uv tool install ipython

RUN curl -fsSL https://claude.ai/install.sh | bash

RUN curl https://sh.rustup.rs -sSf | sh -s -- -y && ~/.cargo/bin/rustup component add rustfmt
ENV PATH="/home/dev/.cargo/bin:/home/dev/.local/bin:${PATH}"

USER root

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
