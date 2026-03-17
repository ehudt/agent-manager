FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    zsh \
    vim-nox \
    git \
    curl \
    wget \
    sudo \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    sharutils \
    xdg-utils \
    unzip \
    tmux \
    openssh-server \
    iproute2 \
    dnsutils \
    iputils-ping \
    jq \
    bat \
    eza \
    ripgrep \
    zoxide \
    gnuplot \
    zstd \
    libzstd-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://tailscale.com/install.sh | sh

RUN mkdir -p /var/run/sshd && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    echo "AuthorizedKeysFile .ssh/authorized_keys" >> /etc/ssh/sshd_config

RUN curl -L https://github.com/junegunn/fzf/releases/download/v0.67.0/fzf-0.67.0-linux_amd64.tar.gz | tar -xz -C /usr/local/bin

# Rename the default ubuntu user to dev
RUN usermod -l dev ubuntu && \
    groupmod -n dev ubuntu && \
    usermod -d /home/dev -m dev && \
    chsh -s /bin/zsh dev && \
    usermod -aG sudo dev && \
    chmod 755 /home/dev

RUN install -d -m 755 -o dev -g dev /home/dev/.codex /home/dev/.codex/tmp

RUN mkdir -p /usr/local/share/zsh/site-functions && \
    git clone https://github.com/sindresorhus/pure.git /tmp/pure && \
    cp /tmp/pure/pure.zsh /usr/local/share/zsh/site-functions/prompt_pure_setup && \
    cp /tmp/pure/async.zsh /usr/local/share/zsh/site-functions/async && \
    rm -rf /tmp/pure

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

# Config defaults restored by entrypoint on first boot
RUN mkdir -p /opt/dev_config
COPY config_context/.zshrc /opt/dev_config/.zshrc
COPY config_context/.vimrc /opt/dev_config/.vimrc
COPY config_context/.tmux.conf /opt/dev_config/.tmux.conf

USER dev
WORKDIR /home/dev

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --component rustfmt
ENV PATH="/home/dev/.cargo/bin:/home/dev/.local/bin:${PATH}"
ENV UV_CACHE_DIR=/tmp/uv-cache

RUN uv python install

RUN uv tool install ipython && \
    uv tool install shell-gpt

RUN curl -fsSL https://claude.ai/install.sh | bash

# Re-lay config files after installers that may clobber .zshrc
COPY --chown=dev:dev config_context/.zshrc /home/dev/.zshrc
COPY --chown=dev:dev config_context/.vimrc /home/dev/.vimrc
COPY --chown=dev:dev config_context/.tmux.conf /home/dev/.tmux.conf

USER root
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
