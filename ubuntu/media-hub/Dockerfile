# Build environment for rebuilding media-hub-server with the repowerd lock
# race fix (patches/). arm64 (runs under qemu-aarch64 binfmt on the x86 host)
# + Ubuntu 24.04 + the UBports 24.04-2.x repo, matching the phone's rootfs.
FROM arm64v8/ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

COPY ubports.gpg /etc/apt/trusted.gpg.d/ubports.gpg
RUN echo "deb http://repo.ubports.com/ 24.04-2.x main" > /etc/apt/sources.list.d/ubports.list

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake pkg-config git ca-certificates lsb-release \
      libapparmor-dev libclick-dev libhybris-dev \
      libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
      libpulse-dev libpulse-mainloop-glib0 \
      qtbase5-dev libtelepathy-qt5-dev \
      libegl1-mesa-dev libgl1-mesa-dev \
      libsnapd-glib-dev libsnapd-qt-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
