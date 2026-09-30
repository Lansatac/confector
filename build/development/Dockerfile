FROM dlang2/dmd-ubuntu:latest AS development

# Install system dependencies, OpenSSL for vibe-d, git, and gdb
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    git \
    gdb \
    libssl-dev \
    zlib1g-dev \
    build-essential \
    curl \
    && rm -rf /var/lib/apt/lists/*

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
    && mkdir -p /code /home/$USERNAME/.dub \
    && chown -R $USERNAME:$USERNAME /code /home/$USERNAME/.dub

WORKDIR /code
USER $USERNAME

CMD ["tail", "-f", "/dev/null"]