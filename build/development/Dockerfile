FROM ubuntu:22.04 AS development
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies, OpenSSL for vibe-d, git, gdb, and ninja
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    gdb \
    libssl-dev \
    zlib1g-dev \
    build-essential \
    xz-utils \
    ninja-build \
    && rm -rf /var/lib/apt/lists/*

# Trust workspace repository paths to prevent dubious ownership warnings with host mounts
RUN git config --system --add safe.directory /code

# Install official DMD compiler and DUB, configure system-wide PATH and libraries
RUN curl -fsS https://dlang.org/install.sh | bash -s install dmd -p /opt/dlang \
    && DMD_DIR=$(find /opt/dlang -maxdepth 1 -name "dmd-*" | head -n 1) \
    && ln -s ${DMD_DIR}/linux/bin64/dmd /usr/local/bin/dmd \
    && ln -s ${DMD_DIR}/linux/bin64/dub /usr/local/bin/dub \
    && ln -s ${DMD_DIR}/linux/bin64/rdmd /usr/local/bin/rdmd \
    && echo "${DMD_DIR}/linux/lib64" > /etc/ld.so.conf.d/dlang.conf && ldconfig \
    && chmod -R a+rX /opt/dlang

    # Pre-build and install Reggae globally to make it universally available in PATH
RUN dub fetch reggae \
    && dub build reggae \
    && REGGAE_BIN=$(find /root/.dub/packages/reggae/ -name reggae -type f -perm /111 | head -n 1) \
    && cp "${REGGAE_BIN}" /usr/local/bin/reggae \
    && rm -rf /root/.dub

# Create a non-root dev user matching standard dev container setups
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=$USER_UID
RUN if id -u $USER_UID >/dev/null 2>&1; then \
        EXISTING_USER=$(getent passwd $USER_UID | cut -d: -f1); \
        userdel -f $EXISTING_USER 2>/dev/null || true; \
    fi \
    && if getent group $USER_GID >/dev/null 2>&1; then \
        EXISTING_GROUP=$(getent group $USER_GID | cut -d: -f1); \
        groupdel $EXISTING_GROUP 2>/dev/null || true; \
    fi \
    && groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $USERNAME \
    && mkdir -p /code/.dub /code/.reggae /code/bin /home/$USERNAME/.dub \
    && chown -R $USERNAME:$USERNAME /code /home/$USERNAME/.dub

WORKDIR /code

USER $USERNAME
CMD ["tail", "-f", "/dev/null"]