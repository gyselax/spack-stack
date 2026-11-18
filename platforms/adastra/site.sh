#!/bin/bash

if [ "${BASH_SOURCE[0]}" -ef "$0" ]
then
    echo "This script must be sourced not executed."
    echo ". $0"
    exit 1
fi

# `module` may be missing in non-interactive shells (e.g. under srun)
if command -v module >/dev/null 2>&1; then module purge; fi

export GYSELA_SPACK_GROUP="gen2224"
export GYSELA_SPACK_JOBS=96
GYSELA_SPACK_VERSION="$(tr -d '[:space:]' < "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/../../spack-version.txt")"
export GYSELA_SPACK_VERSION
export GYSELA_SPACK_PREFIX=${ALL_CCFRWORK}/gysela-spack/${GYSELA_SPACK_VERSION}

# Redirects bazel cache to /tmp to avoid inode saturation, see https://bazel.build/remote/output-directories
export TEST_TMPDIR=/tmp/$USER
export SPACK_DISABLE_LOCAL_CONFIG=true

# Python bytecode cache in a private directory of the temporary space
export PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/${USER:-$(id -un)}/pycache"
