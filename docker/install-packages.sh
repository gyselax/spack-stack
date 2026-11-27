#!/bin/bash
#
# Install system packages in the image, plus the compilers of the architecture
# (run by docker/Dockerfile, in both stages).
#
#   install-packages.sh <arch> <package>...
#
# For the clang-* architectures, LLVM_VERSION is installed from apt.llvm.org,
# with `clang` and `clang++` pointing to it (what Spack detects and CMake uses).

set -euo pipefail

arch="${1:?usage: install-packages.sh <arch> <package>...}"
shift
packages=("$@")
export DEBIAN_FRONTEND=noninteractive

apt-get update
if [[ "${arch}" == clang-* ]]; then
    : "${LLVM_VERSION:?needed for ${arch}}"
    apt-get install -y --no-install-recommends ca-certificates curl
    # shellcheck disable=SC1091
    . /etc/os-release
    install -d /etc/apt/keyrings
    curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key -o /etc/apt/keyrings/apt.llvm.org.asc
    echo "deb [signed-by=/etc/apt/keyrings/apt.llvm.org.asc]" \
        "https://apt.llvm.org/${VERSION_CODENAME}/ llvm-toolchain-${VERSION_CODENAME}-${LLVM_VERSION} main" \
        > /etc/apt/sources.list.d/apt.llvm.org.list
    apt-get update
    packages+=("clang-${LLVM_VERSION}" "libomp-${LLVM_VERSION}-dev")
fi
apt-get install -y --no-install-recommends "${packages[@]}"

if [[ "${arch}" == clang-* ]]; then
    update-alternatives --install /usr/bin/clang clang "/usr/bin/clang-${LLVM_VERSION}" 100 \
        --slave /usr/bin/clang++ clang++ "/usr/bin/clang++-${LLVM_VERSION}"
fi
rm -rf /var/lib/apt/lists/*
