#!/bin/bash
#
# Unified installer for the Gysela toolchains.
#
#   ./install.sh --platform <site> --arch <arch> --project <project> [--project ...] [options]
#
# Several projects can be given (repeat --project, or separate them with commas):
# each gets its own environment, built one after the other with the same Spack.
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
#   install      build and install                            (needs internet)

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
Usage: $(basename "$0") --platform <site> --arch <arch> --project <project> [--project ...] [options]

Options:
  --platform <site>        one of: $(list_dirs "${TOOLCHAIN_ROOT}/platforms" site.sh)
  --arch <arch>            a sub-directory of platforms/<site>/ (e.g. mi250, h100)
  --project <project>      one of: $(list_dirs "${TOOLCHAIN_ROOT}/projects" spack.yaml)
                           (repeat it, or give a comma-separated list, for several)
  --step <step>            all (default) | spack | env | concretize | install
  --force                  delete and recreate the environments that already exist
  -h, --help               show this help
EOF
}

# ---------------------------------------------------------------- arguments
platform="" arch="" step="all"
projects=()
force=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)      platform="${2:?--platform needs a value}"; shift 2 ;;
        --arch)          arch="${2:?--arch needs a value}"; shift 2 ;;
        --project)       IFS=, read -ra _list <<< "${2:?--project needs a value}"
                         projects+=("${_list[@]}"); shift 2 ;;
        --step)          step="${2:?--step needs a value}"; shift 2 ;;
        --force)         force=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               usage >&2; die "unknown argument: $1" ;;
    esac
done

[[ -n "${platform}" && -n "${arch}" && ${#projects[@]} -gt 0 ]] \
    || { usage >&2; die "--platform, --arch and --project are required"; }
case "${step}" in
    all|spack|env|concretize|install) ;;
    *) die "invalid --step '${step}'" ;;
esac

platform_dir="${TOOLCHAIN_ROOT}/platforms/${platform}"
conf_dir="${platform_dir}/${arch}/spack"

[[ -d "${platform_dir}" ]] || die "unknown platform '${platform}' (available: $(list_dirs "${TOOLCHAIN_ROOT}/platforms" site.sh))"
[[ -d "${conf_dir}" ]] || die "unknown arch '${arch}' for ${platform} (available: $(list_dirs "${platform_dir}" spack/packages.yaml))"
[[ -f "${platform_dir}/site.sh" ]] || die "missing ${platform_dir}/site.sh"
for f in externals.yaml packages.yaml; do
    [[ -f "${conf_dir}/${f}" ]] || die "missing ${conf_dir}/${f}"
done
# Each project once, in the order given
mapfile -t projects < <(printf '%s\n' "${projects[@]}" | awk 'NF && !seen[$0]++')
for p in "${projects[@]}"; do
    [[ -f "${TOOLCHAIN_ROOT}/projects/${p}/spack.yaml" ]] \
        || die "unknown project '${p}' (available: $(list_dirs "${TOOLCHAIN_ROOT}/projects" spack.yaml))"
    # Package repositories are normally declared by the project (a platform may add a repos.yaml)
    if [[ ! -f "${conf_dir}/repos.yaml" ]] && ! grep -q '^[[:space:]]*repos:' "${TOOLCHAIN_ROOT}/projects/${p}/spack.yaml"; then
        warn "no package repositories in projects/${p}/spack.yaml nor ${platform}/${arch}: Spack's default builtin repository will be used"
    fi
done

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

# Environment name of a project: the naming rule lives in environment-name.txt
# only (activate.sh reads it too)
environment_name() {
    local name
    name="$(tr -d '[:space:]' < "${TOOLCHAIN_ROOT}/environment-name.txt")"
    name="${name//\{project\}/$1}"
    name="${name//\{arch\}/${arch}}"
    echo "${name//\{version\}/${version}}"
}

# The project the steps below work on
select_project() {
    project="$1"
    project_yaml="${TOOLCHAIN_ROOT}/projects/${project}/spack.yaml"
    env_name="$(environment_name "${project}")"
}
project="" project_yaml="" env_name=""

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
        # The parent (gysela-spack/) holds one Spack per version: let the group add new ones
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
        if [[ "${force}" != 1 ]]; then
            die "environment ${env_name} already exists: pass --force to delete and" \
                "recreate it, or use --step install to resume its installation"
        fi
        info "Deleting the existing environment ${env_name} (--force)"
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

step_install() {
    load_spack
    spack -e "${env_name}" install --jobs "${GYSELA_SPACK_JOBS}"
}

fix_permissions() {
    [[ -d "${GYSELA_SPACK_PREFIX}" ]] || return 0
    info "Sharing ${GYSELA_SPACK_PREFIX} with group ${GYSELA_SPACK_GROUP}"
    find "${GYSELA_SPACK_PREFIX}" -user "${USER}" \( -type d -o -type f \) \
        -exec chgrp "${GYSELA_SPACK_GROUP}" {} + \
        -exec chmod g+rwX {} + || warn "could not fix all permissions"
}

# -------------------------------------------------------------------- main
trap 'trap - EXIT; fix_permissions' EXIT
trap 'echo "error: failed (environment ${env_name:-none}, line ${LINENO})" >&2' ERR

if [[ "${step}" == all ]]; then
    steps=(spack env concretize install)
else
    steps=("${step}")
fi

# Spack is shared by all the projects
if [[ " ${steps[*]} " == *" spack "* ]]; then
    step_spack
fi

# Before building anything, refuse if an environment would be overwritten
if [[ " ${steps[*]} " == *" env "* && "${force}" != 1 \
      && -f "${GYSELA_SPACK_PREFIX}/share/spack/setup-env.sh" ]]; then
    load_spack
    existing=()
    for p in "${projects[@]}"; do
        if spack location --env "$(environment_name "${p}")" >/dev/null 2>&1; then
            existing+=("$(environment_name "${p}")")
        fi
    done
    if [[ ${#existing[@]} -gt 0 ]]; then
        die "already existing: ${existing[*]}: pass --force to delete and recreate" \
            "them, or use --step install to resume their installation"
    fi
fi

for p in "${projects[@]}"; do
    select_project "${p}"
    for s in "${steps[@]}"; do
        [[ "${s}" == spack ]] || "step_${s}"
    done
    info "Done: ${env_name}"
done
for p in "${projects[@]}"; do
    info "Activate ${p} with: . ${TOOLCHAIN_ROOT}/activate.sh --platform ${platform} --arch ${arch} --project ${p}"
done
