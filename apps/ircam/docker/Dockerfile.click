# The click tool, to pack the app tree into a .click. Ubuntu's archive has no
# click package; UBports' 24.04-2.x repository builds it for amd64 too.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
COPY ubports.gpg /etc/apt/trusted.gpg.d/ubports.gpg
RUN echo "deb http://repo.ubports.com/ 24.04-2.x main" > /etc/apt/sources.list.d/ubports.list \
 && apt-get update && apt-get install -y --no-install-recommends click \
 && rm -rf /var/lib/apt/lists/*
# Run with -u "$(id -u):$(id -g)" so the output belongs to you.
WORKDIR /work
