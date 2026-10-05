# Cross-build qtdeclarative (GLES variant) for arm64 from an amd64 host.
# Target: libQt5Quick.so.5.15.13 from qtdeclarative-opensource-src-gles 5.15.13+dfsg-2,
# matching libqt5quick5-gles:arm64 as installed on the device.
#
# Native cross-compilation, NOT qemu emulation: gcc ICEs under qemu-user
# (see DISPLAYPORT-FINDINGS.md section 4), so the compiler must run natively.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
COPY ubports.gpg /etc/apt/trusted.gpg.d/ubports.gpg
RUN rm -f /etc/apt/sources.list.d/ubuntu.sources && \
    printf 'Types: deb deb-src\nURIs: http://archive.ubuntu.com/ubuntu/\nSuites: noble noble-updates noble-backports noble-security\nComponents: main universe restricted multiverse\nArchitectures: amd64\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' > /etc/apt/sources.list.d/amd64.sources && \
    printf 'Types: deb\nURIs: http://ports.ubuntu.com/ubuntu-ports/\nSuites: noble noble-updates noble-backports noble-security\nComponents: main universe restricted multiverse\nArchitectures: arm64\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' > /etc/apt/sources.list.d/arm64.sources && \
    printf 'deb [arch=arm64] http://repo.ubports.com/ 24.04-1.x main\n' > /etc/apt/sources.list.d/ubports.list && \
    dpkg --add-architecture arm64 && apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential crossbuild-essential-arm64 pkg-config \
        devscripts equivs dpkg-dev fakeroot ca-certificates quilt python3 \
        qtbase5-dev-tools qtchooser qt5-qmake perl && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /build
