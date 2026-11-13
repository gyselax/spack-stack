#!/bin/bash
#
# Activate the Spack environment of a project on a platform.
# It must be sourced, so that it changes the current shell (bash):
#
#   . activate.sh --platform <site> --arch <arch> --project <project> [--version <version>]
#
# In order, it
#   1. sources platforms/<site>/site.sh (modules, site variables),
#   2. loads Spack's shell integration (setup-env.sh) from GYSELA_SPACK_PREFIX,
#   3. deactivates the Spack environment that is active, if any,
#   4. activates the environment named after environment-name.txt, with the
#      version from version.txt unless --version selects an older one,
#   5. adds Kokkos Tools to LD_LIBRARY_PATH when the environment provides it.

if [ "${BASH_SOURCE[0]}" -ef "$0" ]
then
    echo "This script must be sourced not executed." >&2
    echo ". $0 --platform <site> --arch <arch> --project <project>" >&2
    exit 1
fi

_gys_activate_usage() {
    cat <<'EOF'
Usage: . activate.sh --platform <site> --arch <arch> --project <project> [--version <version>]

  --platform <site>     a directory of platforms/ (e.g. jean-zay, adastra, local)
  --arch <arch>         a directory of platforms/<site>/ (e.g. h100, mi250, generic)
  --project <project>   a directory of projects/ (e.g. gyselalibxx)
  --version <version>   an installed toolchain version (default: version.txt)
  -h, --help            show this help
EOF
}

_gys_activate() {
    local root platform="" arch="" project="" version="" env_name spack_setup kokkos_tools_dir libdir

    root="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"

    while [ $# -gt 0 ]; do
        case "$1" in
            --platform|--arch|--project|--version)
                if [ $# -lt 2 ] || [ -z "$2" ]; then
                    echo "error: $1 needs a value" >&2
                    return 1
                fi
                case "$1" in
                    --platform) platform="$2" ;;
                    --arch)     arch="$2" ;;
                    --project)  project="$2" ;;
                    --version)  version="$2" ;;
                esac
                shift 2
                ;;
            -h|--help)
                _gys_activate_usage
                return 0
                ;;
            *)
                echo "error: unknown argument: $1" >&2
                _gys_activate_usage >&2
                return 1
                ;;
        esac
    done

    if [ -z "${platform}" ] || [ -z "${arch}" ] || [ -z "${project}" ]; then
        echo "error: --platform, --arch and --project are required" >&2
        _gys_activate_usage >&2
        return 1
    fi
    if [ ! -f "${root}/platforms/${platform}/site.sh" ]; then
        echo "error: unknown platform '${platform}'" >&2
        return 1
    fi
    if [ ! -d "${root}/platforms/${platform}/${arch}/spack" ]; then
        echo "error: unknown arch '${arch}' for ${platform}" >&2
        return 1
    fi
    if [ -z "${version}" ]; then
        version="$(tr -d '[:space:]' < "${root}/version.txt")"
    fi

    # The naming rule lives in environment-name.txt only (install.sh reads it too)
    env_name="$(tr -d '[:space:]' < "${root}/environment-name.txt")"
    env_name="${env_name//\{project\}/${project}}"
    env_name="${env_name//\{arch\}/${arch}}"
    env_name="${env_name//\{version\}/${version}}"

    # Site setup: modules and variables
    # shellcheck disable=SC1090
    . "${root}/platforms/${platform}/site.sh" || return 1

    # Spack's shell integration
    spack_setup="${GYSELA_SPACK_PREFIX:-}/share/spack/setup-env.sh"
    if [ -z "${GYSELA_SPACK_PREFIX:-}" ] || [ ! -f "${spack_setup}" ]; then
        echo "error: Spack is not installed for ${platform} (run ./install.sh --step spack)" >&2
        return 1
    fi
    # shellcheck disable=SC1090
    . "${spack_setup}" || return 1

    if ! spack location --env "${env_name}" >/dev/null 2>&1; then
        echo "error: environment ${env_name} does not exist (run ./install.sh first)" >&2
        return 1
    fi

    if [ -n "${SPACK_ENV:-}" ]; then
        spack env deactivate || return 1
    fi
    spack env activate "${env_name}" || return 1

    # Add Kokkos Tools to the `LD_LIBRARY_PATH` when the environment provides it
    # (lib64 on RHEL-like systems, lib on Debian-like ones)
    if kokkos_tools_dir="$(spack location --install-dir kokkos-tools 2>/dev/null)"; then
        for libdir in lib64 lib; do
            if [ -d "${kokkos_tools_dir}/${libdir}" ]; then
                export LD_LIBRARY_PATH="${kokkos_tools_dir}/${libdir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
                break
            fi
        done
    fi

    echo "==> Activated ${env_name}" >&2
}

_gys_activate "$@"
_gys_activate_status=$?
unset -f _gys_activate _gys_activate_usage
return "${_gys_activate_status}"
