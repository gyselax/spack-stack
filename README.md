# Gysela Spack stack

This repository installs the software stacks of the Gysela projects with
[Spack](https://spack.io), on the supercomputers we use and on personal
machines.

It keeps two things apart:

- **projects** say *what* to install: the list of packages and their versions
  (`projects/<project>/spack.yaml`);
- **platforms** say *how* to install it on a given computer and architecture:
  where Spack lives, which system packages (compilers, MPI, CUDA/ROCm) to reuse,
  which variants to use (`platforms/<site>/…`).

`install.sh` combines one project with one platform and architecture into a
Spack environment, and `activate.sh` activates it in your shell.

## Contents

```
install.sh                  build an environment (Spack, concretize, mirror, install)
activate.sh                 activate an installed environment (to be sourced)
vendor-crates.sh            download Rust crates for offline builds (used by install.sh)
version.txt                 toolchain version, part of every environment name
spack-version.txt           Spack version used on every platform
environment-name.txt        naming rule of the environments: {project}-{arch}-{version}
projects/<project>/
    spack.yaml              specs, concretizer settings, package repositories
platforms/<site>/
    site.sh                 site settings: modules, Spack location, group, jobs, Slurm
    <arch>/spack/
        externals.yaml      system packages Spack must reuse
        packages.yaml       variants, providers, targets, permissions
```

The available platforms and projects are the directories of `platforms/`
and `projects/`; `./install.sh --help` lists them. The `local` platform, with
its `generic` architecture, is meant for a workstation or laptop.

## Requirements

- bash, git, and a Python 3 for Spack itself;
- internet access where `install.sh` runs (on clusters: the login node);
- on platforms in Slurm mode (Jean Zay): a Slurm account allowed on the GPU
  partition;
- on `local`: a GCC with C, C++ and Fortran compilers (`gfortran`), which is
  detected automatically.

## Quick start

On a workstation:

```bash
git clone https://github.com/gyselax/spack-stack.git
cd spack-stack
./install.sh --platform local --arch generic --project gyselalibxx
. ./activate.sh --platform local --arch generic --project gyselalibxx
```

On Jean Zay, from a login node (inside `tmux` or `screen`: the steps that run on
compute nodes block until their job ends):

```bash
export GYSELA_SLURM_ACCOUNT=abc@h100
./install.sh --platform jean-zay --arch h100 --project gyselalibxx
. ./activate.sh --platform jean-zay --arch h100 --project gyselalibxx
```

## Installing an environment: `install.sh`

```
./install.sh --platform <site> --arch <arch> --project <project> [options]

  --step <step>            all (default) | spack | env | concretize | mirror | crates | install
  --slurm-account <acct>   Slurm account (or set GYSELA_SLURM_ACCOUNT)
  --slurm / --no-slurm     force or disable Slurm mode (default: GYSELA_USE_SLURM from site.sh)
```

The environment is named after `environment-name.txt`, for example
`gyselalibxx-h100-v2026-11-12-0`. The steps run in this order:

| Step | What it does | Where (Slurm mode) |
|---|---|---|
| `spack` | clone Spack (`spack-version.txt`) into the platform's prefix, `spack bootstrap now` | login node |
| `env` | (re)create the environment, copy in the project and platform files, `spack repo update`, detect system packages if the platform asks for it | login node |
| `concretize` | concretize, print the specs and the `spack.lock` checksum | compute node |
| `mirror` | download every source into `<prefix>/var/spack/mirror` and use it as a mirror | login node |
| `crates` | download the Rust crates the packages need (see below) | login node |
| `install` | build and install | compute node |

Without Slurm mode (`local`, and clusters whose builds can run where
`install.sh` runs) the `mirror` and `crates` steps are skipped and everything
runs in place.

- **One step at a time:** `--step <step>` runs only that step. This is how to
  resume after a failure, or after a compute-node job reached its time limit:
  `--step install` again continues where Spack stopped.
- **Versions side by side:** `env` deletes and recreates the environment of the
  current version only. To keep the current environment and build a new one next
  to it, bump `version.txt`.
- **Permissions:** at the end, every file you own under the Spack prefix is given
  to the platform's group and made group-readable and writable, so that the
  install can be shared.

## Using an environment: `activate.sh`

```bash
. ./activate.sh --platform <site> --arch <arch> --project <project> [--version <version>]
```

It must be *sourced*. It applies the platform's `site.sh`, loads Spack, leaves
any active Spack environment, activates the requested one (the current
`version.txt` by default, or an older installed `--version`), and adds Kokkos
Tools to `LD_LIBRARY_PATH` when the environment contains it.

In a job script:

```bash
#!/bin/bash
#SBATCH --account=abc@h100
#SBATCH --constraint=h100
#SBATCH --gres=gpu:1

. /path/to/spack-stack/activate.sh --platform jean-zay --arch h100 --project gyselalibxx
srun ./build/my_simulation
```

## Workarounds for Spack limitations

Most of the scripts' logic exists to work around one of these limitations.

**1. Compute nodes without internet.** On some clusters (Jean Zay), GPU nodes
cannot reach the internet, but builds must run there rather than on the login
nodes, whose resources are limited. In Slurm mode `install.sh` therefore runs
`concretize` and `install` on a compute node through `srun`. Every download
happens on the login node beforehand: the sources go into a local Spack mirror,
which the build on the compute node then uses.

**2. Rust crates are not mirrored by Spack.** Packages built with Rust
(`py-maturin`, `py-rpds-py`, `py-libcst`, …) let `cargo` download their
dependencies (crates) during the build. The Spack mirror does not contain them,
so the build fails without internet. The `crates` step (`vendor-crates.sh`)
fixes this:

- on the login node, it downloads the official standalone `cargo` of the same
  version as the environment's `rust` (checksum verified), stages each Rust
  package from the mirror and runs `cargo vendor` into
  `<prefix>/var/spack/cargo-vendor`;
- on the compute node, before building, `install.sh` writes
  `<stage root>/.cargo/config.toml`, telling cargo to take the crates from that
  directory. Cargo reads this file from every parent of its build directory, and
  Spack builds every package below its stage root. Environment variables cannot
  do this, because cargo ignores them for source replacement.

An environment without `rust` skips the step and downloads nothing.
`CARGO=/path/to/cargo` uses another cargo, and `RUST_DIST_SERVER` a mirror of
`https://static.rust-lang.org`. Crates coming from git repositories are not
handled.

**3. Git versions need the network to concretize.** A spec such as
`foo@git.<commit>` makes Spack clone the repository during concretization, to
work out which version that commit is, and that fails on a compute node. Always
give the version: `foo@git.<commit>=<version>`, where `<version>` exists in the
package recipe (for example `py-gysmc@git.f62d…=main`).

**4. `specs:` cannot be included.** Spack includes can carry configuration
(`packages`, `repos`, …) but not the spec list of an environment. Each project
therefore keeps its full `spack.yaml`, and the platform files are attached to
it: `install.sh` copies `platforms/<site>/<arch>/spack/` into
`<environment>/gysela/`, which the projects include. `externals.yaml` is
included by its own name, because a directory include only reads the files
named after a configuration section (`packages.yaml`, `repos.yaml`, …).

**5. Shared installs without `newgrp`/`sg`.** Spack's `permissions:` settings
cover the installed packages, but not its other directories (environments,
repository checkouts, caches). New files also get your primary group rather than
the project's. Since `newgrp` and `sg` are not available, `install.sh` ends by
setting the platform's group (`GYSELA_SPACK_GROUP`) and the group bits on what
you own under the prefix.

**6. Configuration leaking from the user's account.** Every `site.sh` sets
`SPACK_DISABLE_LOCAL_CONFIG=true`, so that `~/.spack` cannot change a build, and
purges the loaded modules. Where `/tmp` is too small for builds (Jean Zay),
`site.sh` points `TMPDIR`, and thus Spack's build stages, to the job's scratch
space.

**7. Run-time library paths.** Spack does not add packages to
`LD_LIBRARY_PATH` when activating an environment, so `activate.sh` does it for
Kokkos Tools, whose libraries are loaded at run time.

## Adding a platform or an architecture

A platform is a computer (or site); an architecture is a kind of node on it. A
platform has one Spack, shared by all its architectures.

**1. Create `platforms/<site>/site.sh`** (to add only an architecture, skip to
step 2). It is sourced by `install.sh` and `activate.sh`, and must export:

| Variable | Meaning |
|---|---|
| `GYSELA_SPACK_PREFIX` | where Spack is cloned and everything is installed: `<base>/gysela/${GYSELA_SPACK_VERSION}`, with `<base>` typically a project scratch or work space |
| `GYSELA_SPACK_VERSION` | read it from `spack-version.txt`, as the existing `site.sh` files do |
| `GYSELA_SPACK_GROUP` | Unix group the install is shared with |
| `GYSELA_SPACK_JOBS` | build parallelism outside Slurm |
| `SPACK_DISABLE_LOCAL_CONFIG` | `true` |

and optionally:

| Variable | Meaning |
|---|---|
| `GYSELA_USE_SLURM=1` | Slurm mode: concretize and install on compute nodes |
| `GYSELA_SLURM_QOS`, `GYSELA_SLURM_TIME` | QoS and time limit of those jobs |
| `GYSELA_SLURM_CPUS_PER_GPU` | CPUs requested per GPU |
| `GYSELA_SLURM_GPUS_CONCRETIZE`, `GYSELA_SLURM_GPUS_INSTALL` | GPUs requested by the two jobs |
| `GYSELA_DETECT_EXTERNALS` | packages to detect with `spack external find` instead of describing them in `externals.yaml` (`local` uses `gcc`) |

Start from the closest existing `site.sh`. Keep the check that refuses to run it
directly, and guard `module purge` with `command -v module`: `module` may not
exist under `srun`.

**2. Create `platforms/<site>/<arch>/spack/`** with:

- **`externals.yaml`**: the system packages Spack must reuse instead of
  building, with `buildable: false`, usually the compilers, MPI and CUDA or ROCm.
  `spack external find <package>` run on the machine gives a starting point.
  Only compiler packages (`gcc`, `llvm-amdgpu`, …) need
  `extra_attributes: compilers:` with `c`, `cxx` (and `fortran`) paths; for
  other packages it is ignored.
- **`packages.yaml`**: the choices for this hardware: the CPU target, the GPU
  backend and architecture (`+cuda cuda_arch=90`, `+rocm amdgpu_target=gfx90a`,
  …), the MPI and LAPACK providers, and the `permissions` of the installs.

An architecture is recognised by its `spack/packages.yaml`; `install.sh` lists
the available ones. In Slurm mode, the directory name is also passed to `srun`
as `--constraint`, so it must be a valid Slurm constraint of the site (for
example `h100`).

**3. Try it:** `./install.sh --platform <site> --arch <arch> --project gyselalibxx --step concretize`
shows whether the externals and preferences give a sensible concretization,
before spending hours building.

## Adding a project

**1. Create `projects/<project>/spack.yaml`**, starting from an existing one.
Keep its first lines, which attach the platform files:

```yaml
spack:
  include:
    - path: gysela/externals.yaml
      optional: true
    - path: gysela
      optional: true
  specs:
    - cxx
    - mpi
    - kokkos@5.1
    # ...
  concretizer:
    reuse: false
    unify: true
  repos:
    patches:
      git: https://github.com/gyselax/spack.git
      commit: <commit>
      destination: $env/repos/gysela-patches
    builtin:
      tag: v2026.10.1
      destination: $spack/var/spack/repos/builtin-v2026.10.1
```

**2. Pin what you install.** Give versions to the specs, and a commit or tag to
the package repositories (`repos:`), so that a toolchain version always builds
the same software. A project with no `repos:` gets Spack's default repository,
and `install.sh` warns about it.

**3. Keep it platform-neutral.** Variants that depend on the hardware (GPU
backend, MPI, targets) belong to the platforms' `packages.yaml`. Project-wide
preferences can go in the project's own `packages:` section, which takes
precedence over the platform files.

**4. Follow the rules above for air-gapped builds:** give git versions their
`=<version>` suffix, and remember that packages built with Rust only work there
through the `crates` step.

The project is then available to `install.sh` and `activate.sh` under its
directory name.

## Updating a toolchain

- **New package versions or settings:** edit the project or platform files, then
  bump `version.txt`, so that the new environment is built next to the old one
  and existing users and job scripts are not disturbed.
- **New Spack version:** change `spack-version.txt`. Since the prefix contains
  the version, every platform then gets a new Spack, and `--step spack` (or a
  full run) clones it.
- **New package repositories:** update the `commit` and `tag` in the projects'
  `repos:` sections.
