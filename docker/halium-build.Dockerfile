# Halium 14.0 / LineageOS 21 (Android 14) build environment
# Target device: OnePlus 8 Pro (instantnoodlep, sm8250 "kona")
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

# --- AOSP / LineageOS 21 build dependencies -------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    bc bison build-essential ccache curl flex g++-multilib gcc-multilib \
    git git-lfs gnupg gperf imagemagick \
    lib32ncurses-dev lib32readline-dev lib32z1-dev \
    libelf-dev liblz4-tool libncurses5 libsdl1.2-dev libssl-dev \
    libxml2 libxml2-utils \
    lzop pngcrush rsync schedtool squashfs-tools xsltproc zip unzip zlib1g-dev \
    openjdk-17-jdk python3 python-is-python3 \
    android-sdk-libsparse-utils fontconfig ca-certificates sudo procps \
    && rm -rf /var/lib/apt/lists/*

# --- Google's repo tool ---------------------------------------------------
RUN curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
      -o /usr/local/bin/repo \
    && chmod a+x /usr/local/bin/repo

# --- Unprivileged user matching the host UID so bind-mounted files ---------
# --- keep the right ownership ---------------------------------------------
ARG UID=1000
RUN useradd -m -u ${UID} -s /bin/bash build \
    && echo 'build ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/build

USER build
WORKDIR /work

# Keep ccache inside the project folder, not in the image or the host home.
ENV USE_CCACHE=1 \
    CCACHE_DIR=/work/.ccache \
    CCACHE_EXEC=/usr/bin/ccache \
    LC_ALL=C.UTF-8
