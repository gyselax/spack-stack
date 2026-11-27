#!/bin/bash
#
# Build the Spack environment of the image (run by docker/Dockerfile).
#
#   build-env.sh <env-dir>
#
# Environment variables:
#   BUILDCACHE        OCI build cache (oci://registry/owner/name), empty for none
#   PUSH_BUILDCACHE   true: push every package built here to BUILDCACHE
#   REGISTRY_USER     user for BUILDCACHE
#   REGISTRY_TOKEN    token for BUILDCACHE (from a BuildKit secret)

set -euo pipefail

# Every spack command below works on this environment
export SPACK_ENV="${1:?usage: build-env.sh <env-dir>}"
: "${BUILDCACHE:=}" "${PUSH_BUILDCACHE:=false}"
export REGISTRY_USER="${REGISTRY_USER:-}" REGISTRY_TOKEN="${REGISTRY_TOKEN:-}"

# Same install tree in the build cache and in every image
spack config add 'config:install_tree:root:/opt/software'
spack repo update
spack concretize --quiet
spack spec --install-status --long --namespaces --types

if [[ -n "${BUILDCACHE}" ]]; then
    # --autopush: push each package as soon as it is built from source, build
    # dependencies included, so that a failed or cancelled build keeps what it
    # built. Only the names of the variables are written in the configuration.
    push=()
    [[ "${PUSH_BUILDCACHE}" == true ]] && push=(--autopush)
    spack mirror add --type binary --unsigned "${push[@]}" \
        --oci-username-variable REGISTRY_USER --oci-password-variable REGISTRY_TOKEN \
        gysela-buildcache "${BUILDCACHE}"
fi

status=0
spack install --use-buildcache auto --jobs "$(nproc)" || status=$?

if [[ -n "${BUILDCACHE}" ]]; then
    if [[ "${PUSH_BUILDCACHE}" == true ]]; then
        # Make the pushed packages visible to the next builds, even after a failure
        spack buildcache update-index gysela-buildcache || status=1
    fi
    spack mirror remove gysela-buildcache
fi
[[ "${status}" == 0 ]] || exit "${status}"

# Keep only what the environment needs at run time, and save its activation
spack gc --yes-to-all
spack clean --all
spack env activate --sh "${SPACK_ENV}" > /opt/activate-env.sh
