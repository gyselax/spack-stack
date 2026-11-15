#!/bin/bash
#
# Download the Rust crates needed by an environment, for offline builds.
# Run it where there is internet (a login node), after concretizing and,
# ideally, after the source mirror is set up (Spack then stages from it):
#
#   ./vendor-crates.sh <environment> <vendor-directory>
#
# install.sh runs it as its `crates` step in Slurm mode, then points cargo
# at <vendor-directory> on the compute node before building.
#
# Every crate ends up in <vendor-directory>, shared by all packages
# (one sub-directory per crate version).
#
# If the environment has no rust, nothing is done and nothing is downloaded.
# Otherwise cargo is the official standalone cargo of the same version as the
# environment's rust, downloaded once (checksum verified) next to
# <vendor-directory>; `cargo vendor` needs no rustc. Set CARGO=/path/to/cargo
# to use another cargo, or RUST_DIST_SERVER to download from a mirror of
# https://static.rust-lang.org.

set -euo pipefail
shopt -s inherit_errexit  # also stop on errors inside $(...)

env_name="${1:?usage: $0 <environment> <vendor-directory>}"
vendor_dir="${2:?usage: $0 <environment> <vendor-directory>}"
dist_server="${RUST_DIST_SERVER:-https://static.rust-lang.org}"

# The environment's rust version and its packages that build with Rust
# (`spack python -c` takes only one statement, hence the script file)
finder="$(mktemp)"
workdir=""
trap 'rm -rf "${finder}" ${workdir:+"${workdir}"}' EXIT
cat > "${finder}" <<'PY'
import spack.deptypes as dt
import spack.environment as ev

for spec in ev.active_environment().all_specs():
    if spec.name == "rust":
        print("rust", spec.dag_hash(), spec.version)
    elif spec.dependencies("rust", deptype=dt.BUILD):
        print("package", spec.dag_hash(), spec.format("{name}@{version}"))
PY
listing="$(spack -e "${env_name}" python "${finder}")"

rust_versions=()
packages=()
while read -r kind hash name; do
    case "${kind}" in
        rust)    rust_versions+=("${name}") ;;
        package) packages+=("${hash} ${name}") ;;
    esac
done <<< "${listing}"

if [[ ${#rust_versions[@]} -eq 0 ]]; then
    echo "==> No rust in ${env_name}: nothing to download"
    exit 0
fi
if [[ ${#packages[@]} -eq 0 ]]; then
    echo "==> No package of ${env_name} builds with Rust: nothing to download"
    exit 0
fi
echo "==> ${#packages[@]} package(s) build with Rust"

# Standalone cargo matching the environment's rust
download_cargo() {
    local version="$1" triple archive url dest expected actual cargo_bin
    triple="$(uname -m)-unknown-linux-gnu"
    archive="cargo-${version}-${triple}.tar.xz"
    url="${dist_server}/dist/${archive}"
    dest="$(dirname -- "${vendor_dir}")/cargo-toolchains/cargo-${version}-${triple}"

    if [[ -x "${dest}/bin/cargo" ]]; then
        echo "${dest}/bin/cargo"
        return 0
    fi
    if ! [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "error: rust@${version} has no standalone cargo release: set CARGO=/path/to/cargo" >&2
        return 1
    fi

    echo "==> Downloading ${url}" >&2
    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location --output "${workdir}/${archive}" "${url}"
        curl --fail --silent --show-error --location --output "${workdir}/${archive}.sha256" "${url}.sha256"
    else
        wget --quiet --output-document "${workdir}/${archive}" "${url}"
        wget --quiet --output-document "${workdir}/${archive}.sha256" "${url}.sha256"
    fi
    expected="$(cut -d' ' -f1 < "${workdir}/${archive}.sha256")"
    actual="$(sha256sum "${workdir}/${archive}" | cut -d' ' -f1)"
    if [[ -z "${expected}" || "${expected}" != "${actual}" ]]; then
        echo "error: checksum mismatch for ${archive} (expected ${expected:-nothing}, got ${actual})" >&2
        return 1
    fi

    tar -xJf "${workdir}/${archive}" -C "${workdir}"
    cargo_bin="$(find "${workdir}" -path '*/bin/cargo' -type f | head -1)"
    if [[ -z "${cargo_bin}" ]]; then
        echo "error: no bin/cargo in ${archive}" >&2
        return 1
    fi
    mkdir -p "${dest}/bin"
    cp "${cargo_bin}" "${dest}/bin/cargo"
    chmod +x "${dest}/bin/cargo"
    echo "${dest}/bin/cargo"
}

if [[ -z "${CARGO:-}" ]]; then
    workdir="$(mktemp -d)"   # for the download, removed on exit
    if [[ ${#rust_versions[@]} -gt 1 ]]; then
        echo "warning: several rust versions in ${env_name} (${rust_versions[*]}): using ${rust_versions[0]}" >&2
    fi
    CARGO="$(download_cargo "${rust_versions[0]}")"
fi
[[ -x "${CARGO}" ]] || { echo "error: ${CARGO} is not an executable" >&2; exit 1; }
echo "==> Using $("${CARGO}" --version)"

mkdir -p "${vendor_dir}"
for entry in "${packages[@]}"; do
    spec="/${entry%% *}"
    echo "==> ${entry#* }"
    spack -e "${env_name}" stage "${spec}" >/dev/null
    src="$(spack -e "${env_name}" location --source-dir "${spec}")"

    # Vendor each Cargo project of the source, located by its Cargo.lock;
    # without any Cargo.lock, fall back to the top-most Cargo.toml.
    mapfile -t manifests < <(find "${src}" -name Cargo.lock -not -path '*/target/*' -printf '%h/Cargo.toml\n')
    if [[ ${#manifests[@]} -eq 0 ]]; then
        mapfile -t manifests < <(find "${src}" -name Cargo.toml -not -path '*/target/*' -printf '%d %p\n' | sort -n | head -1 | cut -d' ' -f2-)
    fi
    for manifest in "${manifests[@]}"; do
        [[ -f "${manifest}" ]] || continue
        echo "    cargo vendor ${manifest#"${src}"/}"
        "${CARGO}" vendor --quiet --versioned-dirs --no-delete --manifest-path "${manifest}" "${vendor_dir}" >/dev/null
    done

    spack -e "${env_name}" clean "${spec}" >/dev/null
done
echo "==> $(find "${vendor_dir}" -mindepth 1 -maxdepth 1 -type d | wc -l) crate(s) in ${vendor_dir}"
