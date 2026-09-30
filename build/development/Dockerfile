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

RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $USERNAME \
    && mkdir -p /code /home/$USERNAME/.dub \
    && chown -R $USERNAME:$USERNAME /code /home/$USERNAME/.dub

WORKDIR /code
USER $USERNAME

CMD ["tail", "-f", "/dev/null"]