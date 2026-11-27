# syntax=docker/dockerfile:1
#
# Image of a project's Spack environment on a generic platform:
#
#   docker build -f docker/Dockerfile \
#       --build-arg PROJECT=gyselalibxx --build-arg ARCH=openmp \
#       --build-arg SPACK_VERSION="$(cat spack-version.txt)" .
#
# The environment is made of
#   projects/<PROJECT>/spack.yaml                   (specs, package repositories)
#   platforms/generic/<ARCH>/spack/*.yaml           (packages, env_vars), included from gysela/
#
# With BUILDCACHE set to an OCI registry (oci://ghcr.io/<owner>/<name>), packages
# are taken from it when already built, and, with PUSH_BUILDCACHE=true, every
# package built here is pushed to it as soon as it is installed. The registry
# token comes from the BuildKit secret `registry_token`, it is not stored in the image.

ARG BASE_IMAGE=ubuntu:24.04

# ======================================================================= build
FROM ${BASE_IMAGE} AS builder

ARG PROJECT
ARG ARCH
ARG SPACK_VERSION
ARG BUILDCACHE=""
ARG PUSH_BUILDCACHE=false
ARG REGISTRY_USER=""

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Compilers (gfortran: e.g. py-scipy needs one) and what Spack needs to fetch and build
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bzip2 ca-certificates curl file g++ gfortran git gzip make patch \
      python3 tar unzip xz-utils zstd \
 && rm -rf /var/lib/apt/lists/*

RUN : "${PROJECT:?}" "${ARCH:?}" "${SPACK_VERSION:?}" \
 && git clone --depth 1 --branch "v${SPACK_VERSION}" https://github.com/spack/spack.git /opt/spack

# The environment: the project's spack.yaml, the platform files where it includes them
COPY projects/${PROJECT}/spack.yaml /opt/env/spack.yaml
COPY platforms/generic/${ARCH}/spack/ /opt/env/gysela/

COPY docker/build-env.sh /opt/build-env.sh
ENV PATH=/opt/spack/bin:${PATH}

# The registry token is only mounted for this step, it is not stored in the image
# (the ARGs above reach the script as environment variables)
RUN --mount=type=secret,id=registry_token,env=REGISTRY_TOKEN \
    /opt/build-env.sh /opt/env

# ===================================================================== runtime
FROM ${BASE_IMAGE}

ARG PROJECT
ARG ARCH

# The compilers of the build: Spack detected them as externals, and users compile here
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates g++ gfortran git make \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/spack /opt/spack
COPY --from=builder /opt/software /opt/software
COPY --from=builder /opt/env /opt/env
COPY --from=builder /opt/activate-env.sh /opt/activate-env.sh

ENV GYSELA_PROJECT=${PROJECT} \
    GYSELA_ARCH=${ARCH}

# Run as a regular user (Open MPI refuses to run as root). UID 1000 is the usual
# UID of the first user of a workstation, so files written in a mounted source
# tree belong to the developer; `docker run --user "$(id -u):$(id -g)"` for others.
# The environment stays owned by root: it cannot be modified from the image.
ARG USER_UID=1000
RUN if id -nu "${USER_UID}" >/dev/null 2>&1; then userdel --remove "$(id -nu "${USER_UID}")"; fi \
 && useradd --create-home --uid "${USER_UID}" --shell /bin/bash gysela
USER gysela
WORKDIR /home/gysela

# Every command runs inside the environment
ENTRYPOINT ["/bin/bash", "-c", ". /opt/activate-env.sh && exec \"$@\"", "--"]
CMD ["/bin/bash"]
