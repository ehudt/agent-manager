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
    openssh-server \
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

RUN mkdir -p /var/run/sshd && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    echo "AuthorizedKeysFile .ssh/authorized_keys" >> /etc/ssh/sshd_config

# Rename the default ubuntu user to dev
RUN usermod -l dev ubuntu && \
    groupmod -n dev ubuntu && \
    usermod -d /home/dev -m dev && \
    chsh -s /bin/zsh dev && \
    usermod -aG sudo dev

RUN install -d -m 755 -o dev -g dev /home/dev/.codex /home/dev/.codex/tmp

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Preinstall Playwright runtime dependencies and Chromium for UI tests.
ARG PLAYWRIGHT_VERSION=1.51.1
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npx -y playwright@${PLAYWRIGHT_VERSION} install-deps chromium && \
    npx -y playwright@${PLAYWRIGHT_VERSION} install chromium && \
    chmod -R 755 /ms-playwright

RUN npm install -g @openai/codex
RUN curl -fsSL https://claude.ai/install.sh | bash

# Config defaults restored by entrypoint on first boot
RUN mkdir -p /opt/dev_config
COPY config_context/.zshrc /opt/dev_config/.zshrc
COPY config_context/.vimrc /opt/dev_config/.vimrc

RUN curl https://sh.rustup.rs -sSf | sh -s -- -y && \
    /root/.cargo/bin/rustup component add rustfmt && \
    ln -sf /root/.cargo/bin/cargo /usr/local/bin/cargo && \
    ln -sf /root/.cargo/bin/rustc /usr/local/bin/rustc && \
    ln -sf /root/.cargo/bin/rustfmt /usr/local/bin/rustfmt && \
    ln -sf /root/.cargo/bin/rustup /usr/local/bin/rustup

RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
ENV UV_CACHE_DIR=/tmp/uv-cache
ENV UV_TOOL_BIN_DIR=/usr/local/bin
ENV UV_TOOL_DIR=/opt/uv-tools

RUN uv python install

RUN uv tool install ipython

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
