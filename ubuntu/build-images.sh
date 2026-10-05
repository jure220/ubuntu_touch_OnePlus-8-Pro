#!/bin/bash
# Build the Docker images used to build the Ubuntu-side components (see
# BUILDING.md, step 2). The qtmir images are layered; the tags are the names
# the build scripts expect.
set -euo pipefail
cd "$(dirname "$0")"
b() { tag=$1; shift; echo "== $tag"; docker build -t "$tag" "$@" .; }

b qtmircross:2 -f qtmir/Dockerfile.cross
b qtmircross:3 -f qtmir/Dockerfile.cross2x-a
b qtmircross:4 -f qtmir/Dockerfile.cross2x-b
b qtmircross:5 -f qtmir/Dockerfile.cross2x-c
b qtmircross:6 -f qtmir/Dockerfile.cross2x-d
b mircross:1 -f mir/Dockerfile.mircross
b android2cross:1 -f mir-android2-platform/Dockerfile.android2
b qtbuild:1 -f qtdeclarative/Dockerfile
b qtbuild:deps -f qtdeclarative/Dockerfile.deps
b qtbuild:deps3 -f qtdeclarative/Dockerfile.deps3
b media-hub-build:24.04 --platform linux/arm64 -f media-hub/Dockerfile
