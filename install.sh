#!/bin/bash
#
# Unified installer for the Gysela toolchains.
#
#   ./install.sh --platform <site> --arch <arch> --project <project> [options]
#
# It combines
#   projects/<project>/spack.yaml          (what to install, package repositories)
#   platforms/<site>/site.sh               (site variables, Spack location)
#   platforms/<site>/<arch>/spack/*.yaml   (externals, packages)
# into a Spack environment named after environment-name.txt, by default
# "<project>-<arch>-<version>" (version.txt). Activate it with activate.sh.
#
# Steps (run in this order by default, `--step` runs only one):
#   spack        clone Spack and bootstrap it                 (needs internet)
#   env          (re)create the environment, update repos, detect system packages (needs internet)
#   concretize   concretize the environment
#   mirror       download all sources to a local mirror       (Slurm mode only)
#   crates       download the Rust crates for offline builds  (Slurm mode only)
#   install      build and install
# In Slurm mode (GYSELA_USE_SLURM=1 in site.sh, or --slurm), `concretize` and
# `install` run on a compute node through srun, the others on the login node.

# Ensures the script is not being sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    echo "This script must be executed, not sourced!" >&2
    return 1
fi

set -Eeuo pipefail

SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
TOOLCHAIN_ROOT="$(dirname -- "${SELF}")"
export PYTHONDONTWRITEBYTECODE=True

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
info() { echo "==> $*"; }

# List sub-directories of $1 (optionally only those containing file $2)
list_dirs() {
    local d name
    for d in "$1"/*/; do
        name="$(basename -- "${d}")"
        [[ -z "${2:-}" || -f "${d}${2}" ]] && printf '%s\n' "${name}"
    done | paste -sd' '
}

usage() {
    cat <<EOF
Usage: $(basename "$0") --platform <site> --arch <arch> --project <project> [options]

Options:
  --platform <site>        one of: $(list_dirs "${TOOLCHAIN_ROOT}/platforms" site.sh)
  --arch <arch>            a sub-directory of platforms/<site>/ (e.g. mi250, h100)
  --project <project>      one of: $(list_dirs "${TOOLCHAIN_ROOT}/projects" spack.yaml)
  --step <step>            all (default) | spack | env | concretize | mirror | crates | install
  --slurm-account <acct>   Slurm account (or set GYSELA_SLURM_ACCOUNT)
  --slurm / --no-slurm     force or disable Slurm mode (default: GYSELA_USE_SLURM from site.sh)
  -h, --help               show this help
EOF
}

# ---------------------------------------------------------------- arguments
platform="" arch="" project="" step="all"
slurm_account="${GYSELA_SLURM_ACCOUNT:-}"
slurm_override=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)      platform="${2:?--platform needs a value}"; shift 2 ;;
        --arch)          arch="${2:?--arch needs a value}"; shift 2 ;;
        --project)       project="${2:?--project needs a value}"; shift 2 ;;
        --step)          step="${2:?--step needs a value}"; shift 2 ;;
        --slurm-account) slurm_account="${2:?--slurm-account needs a value}"; shift 2 ;;
        --slurm)         slurm_override=1; shift ;;
        --no-slurm)      slurm_override=0; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               usage >&2; die "unknown argument: $1" ;;
    esac
done

[[ -n "${platform}" && -n "${arch}" && -n "${project}" ]] \
    || { usage >&2; die "--platform, --arch and --project are required"; }
case "${step}" in
    all|spack|env|concretize|mirror|crates|install) ;;
    *) die "invalid --step '${step}'" ;;
esac

platform_dir="${TOOLCHAIN_ROOT}/platforms/${platform}"
conf_dir="${platform_dir}/${arch}/spack"
project_yaml="${TOOLCHAIN_ROOT}/projects/${project}/spack.yaml"

[[ -d "${platform_dir}" ]] || die "unknown platform '${platform}' (available: $(list_dirs "${TOOLCHAIN_ROOT}/platforms" site.sh))"
[[ -d "${conf_dir}" ]] || die "unknown arch '${arch}' for ${platform} (available: $(list_dirs "${platform_dir}" spack/packages.yaml))"
[[ -f "${project_yaml}" ]] || die "unknown project '${project}' (available: $(list_dirs "${TOOLCHAIN_ROOT}/projects" spack.yaml))"
[[ -f "${platform_dir}/site.sh" ]] || die "missing ${platform_dir}/site.sh"
for f in externals.yaml packages.yaml; do
    [[ -f "${conf_dir}/${f}" ]] || die "missing ${conf_dir}/${f}"
done
# Package repositories are normally declared by the project (a platform may add a repos.yaml)
if [[ ! -f "${conf_dir}/repos.yaml" ]] && ! grep -q '^[[:space:]]*repos:' "${project_yaml}"; then
    warn "no package repositories in projects/${project}/spack.yaml nor ${platform}/${arch}: Spack's default builtin repository will be used"
fi

# ------------------------------------------------------------- site config
# site.sh reads site variables that may be unset (e.g. PROJECT): not `set -u` clean.
set +u
# shellcheck disable=SC1091
. "${platform_dir}/site.sh"
set -u

: "${GYSELA_SPACK_GROUP:?not set by ${platform}/site.sh}"
: "${GYSELA_SPACK_JOBS:?not set by ${platform}/site.sh}"
: "${GYSELA_SPACK_VERSION:?not set by ${platform}/site.sh}"
: "${GYSELA_SPACK_PREFIX:?not set by ${platform}/site.sh}"

version="$(tr -d '[:space:]' < "${TOOLCHAIN_ROOT}/version.txt")"
# The naming rule lives in environment-name.txt only (activate.sh reads it too)
env_name="$(tr -d '[:space:]' < "${TOOLCHAIN_ROOT}/environment-name.txt")"
env_name="${env_name//\{project\}/${project}}"
env_name="${env_name//\{arch\}/${arch}}"
env_name="${env_name//\{version\}/${version}}"

use_slurm="${slurm_override:-${GYSELA_USE_SLURM:-0}}"
if [[ "${use_slurm}" == 1 && -z "${GYSELA_INSTALL_WORKER:-}" ]]; then
    [[ -n "${slurm_account}" ]] || die "Slurm mode needs --slurm-account (or GYSELA_SLURM_ACCOUNT)"
    command -v srun >/dev/null 2>&1 || die "srun not found"
    : "${GYSELA_SLURM_CPUS_PER_GPU:?not set by ${platform}/site.sh}"
    : "${GYSELA_SLURM_QOS:?not set by ${platform}/site.sh}"
    : "${GYSELA_SLURM_TIME:?not set by ${platform}/site.sh}"
    : "${GYSELA_SLURM_GPUS_CONCRETIZE:?not set by ${platform}/site.sh}"
    : "${GYSELA_SLURM_GPUS_INSTALL:?not set by ${platform}/site.sh}"
fi

mirror_dir="${GYSELA_SPACK_PREFIX}/var/spack/mirror"
cargo_vendor_dir="${GYSELA_SPACK_PREFIX}/var/spack/cargo-vendor"

# ------------------------------------------------------------------- steps
load_spack() {
    local setup="${GYSELA_SPACK_PREFIX}/share/spack/setup-env.sh"
    [[ -f "${setup}" ]] || die "Spack not found in ${GYSELA_SPACK_PREFIX} (run with --step spack first)"
    set +u
    # shellcheck disable=SC1090
    . "${setup}"
    set -u
}

step_spack() {
    info "Spack ${GYSELA_SPACK_VERSION} in ${GYSELA_SPACK_PREFIX}"
    if [[ ! -f "${GYSELA_SPACK_PREFIX}/share/spack/setup-env.sh" ]]; then
        mkdir --parents "${GYSELA_SPACK_PREFIX}"
        # The parent (gysela/) holds one Spack per version: let the group add new ones
        local parent
        parent="$(dirname -- "${GYSELA_SPACK_PREFIX}")"
        if [[ -O "${parent}" ]]; then
            { chgrp "${GYSELA_SPACK_GROUP}" "${parent}" && chmod g+rwxs "${parent}"; } \
                || warn "could not share ${parent} with group ${GYSELA_SPACK_GROUP}"
        fi
        chmod g+s "${GYSELA_SPACK_PREFIX}"
        git clone --branch "v${GYSELA_SPACK_VERSION}" --depth 1 \
            https://github.com/spack/spack.git "${GYSELA_SPACK_PREFIX}"
    fi
    load_spack
    # Must happen on a node with internet access
    spack bootstrap now
}

step_env() {
    load_spack
    info "Preparing the Spack environment ${env_name}"
    if spack location --env "${env_name}" >/dev/null 2>&1; then
        spack env remove --yes-to-all "${env_name}"
    fi
    spack env create "${env_name}"

    local env_dir
    env_dir="$(spack location --env "${env_name}")"
    cp "${project_yaml}" "${env_dir}/spack.yaml"
    mkdir --parents "${env_dir}/gysela"
    cp -r "${conf_dir}"/. "${env_dir}/gysela/"

    spack -e "${env_name}" repo update

    # Sites without a hand-written externals.yaml can let Spack detect system packages
    if [[ -n "${GYSELA_DETECT_EXTERNALS:-}" ]]; then
        info "Detecting system packages: ${GYSELA_DETECT_EXTERNALS}"
        # shellcheck disable=SC2086
        spack -e "${env_name}" external find ${GYSELA_DETECT_EXTERNALS}
    fi
}

step_concretize() {
    load_spack
    spack -e "${env_name}" concretize --quiet
    spack -e "${env_name}" spec --install-status --long --namespaces --types
    local lock
    lock="$(spack location --env "${env_name}")/spack.lock"
    info "Lockfile: ${lock}"
    sha256sum "${lock}"
}

step_mirror() {
    load_spack
    info "Mirroring sources into ${mirror_dir}"
    spack -e "${env_name}" mirror create --all --directory "${mirror_dir}"
    spack -e "${env_name}" mirror remove local_filesystem >/dev/null 2>&1 || true
    spack -e "${env_name}" mirror add local_filesystem "${mirror_dir}"
}

step_crates() {
    load_spack
    info "Downloading Rust crates into ${cargo_vendor_dir}"
    "${TOOLCHAIN_ROOT}/vendor-crates.sh" "${env_name}" "${cargo_vendor_dir}"
}

# Make cargo use the crates of the `crates` step instead of crates.io.
# Cargo reads .cargo/config.toml from every parent of its build directory,
# and Spack builds each package below its stage root (which it leaves alone).
use_vendored_crates() {
    local stage_root
    stage_root="$(spack -e "${env_name}" location --stages)"
    info "Using the Rust crates of ${cargo_vendor_dir} (${stage_root}/.cargo/config.toml)"
    mkdir --parents "${stage_root}/.cargo"
    cat > "${stage_root}/.cargo/config.toml" <<EOF
# Written by install.sh: use the crates downloaded on the login node
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "${cargo_vendor_dir}"
EOF
}

step_install() {
    load_spack
    # On an air-gapped compute node, build Rust packages from the downloaded crates
    if [[ -n "${GYSELA_INSTALL_WORKER:-}" && -n "$(ls -A "${cargo_vendor_dir}" 2>/dev/null)" ]]; then
        use_vendored_crates
    fi
    spack -e "${env_name}" install --jobs "${SLURM_CPUS_PER_TASK:-${GYSELA_SPACK_JOBS}}"
}

fix_permissions() {
    [[ -d "${GYSELA_SPACK_PREFIX}" ]] || return 0
    info "Sharing ${GYSELA_SPACK_PREFIX} with group ${GYSELA_SPACK_GROUP}"
    find "${GYSELA_SPACK_PREFIX}" -user "${USER}" \( -type d -o -type f \) \
        -exec chgrp "${GYSELA_SPACK_GROUP}" {} + \
        -exec chmod g+rwX {} + || warn "could not fix all permissions"
}

# Run a step on a compute node (Slurm mode) or directly
run_on_compute_node() {
    local name="$1" gpus="$2"
    local cpus=$(( gpus * GYSELA_SLURM_CPUS_PER_GPU ))
    info "srun: ${name} (${gpus} GPU(s), ${cpus} CPUs)"
    GYSELA_INSTALL_WORKER=1 srun \
        --account="${slurm_account}" \
        --constraint="${arch}" \
        --ntasks=1 \
        --gres="gpu:${gpus}" \
        --cpus-per-task="${cpus}" \
        --time="${GYSELA_SLURM_TIME}" \
        --qos="${GYSELA_SLURM_QOS}" \
        bash "${SELF}" --platform "${platform}" --arch "${arch}" --project "${project}" --step "${name}"
}

run_step() {
    local name="$1"
    if [[ -n "${GYSELA_INSTALL_WORKER:-}" || "${use_slurm}" != 1 ]]; then
        "step_${name}"
        return
    fi
    case "${name}" in
        concretize) run_on_compute_node concretize "${GYSELA_SLURM_GPUS_CONCRETIZE}" ;;
        install)    run_on_compute_node install "${GYSELA_SLURM_GPUS_INSTALL}" ;;
        *)          "step_${name}" ;;
    esac
}

# -------------------------------------------------------------------- main
if [[ -n "${GYSELA_INSTALL_WORKER:-}" ]]; then
    # Running inside srun: execute exactly one step, no permission handling.
    [[ "${step}" != all ]] || die "internal error: worker needs an explicit step"
    run_step "${step}"
    exit 0
fi

trap 'trap - EXIT; fix_permissions' EXIT
trap 'echo "error: failed (environment ${env_name}, line ${LINENO})" >&2' ERR

if [[ "${step}" == all ]]; then
    steps=(spack env concretize)
    [[ "${use_slurm}" == 1 ]] && steps+=(mirror crates)
    steps+=(install)
else
    steps=("${step}")
fi
for s in "${steps[@]}"; do
    run_step "${s}"
done
info "Done: ${env_name}"
info "Activate it with: . ${TOOLCHAIN_ROOT}/activate.sh --platform ${platform} --arch ${arch} --project ${project}"
