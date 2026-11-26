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
install.sh                  build an environment (Spack, concretize, install)
activate.sh                 activate an installed environment (to be sourced)
version.txt                 toolchain version, part of every environment name
spack-version.txt           Spack version used on every platform
environment-name.txt        naming rule of the environments: {project}-{arch}-{version}
cmake/CMakePresets.json     CMake presets to build a project against an environment
projects/<project>/
    spack.yaml              specs, concretizer settings, package repositories
platforms/<site>/
    site.sh                 site settings: modules, Spack location, group, jobs
    <arch>/spack/
        externals.yaml      system packages Spack must reuse
        packages.yaml       variants, providers, targets, permissions
        env_vars.yaml       compilers and flags used by the CMake presets
```

The available platforms and projects are the directories of `platforms/`
and `projects/`; `./install.sh --help` lists them. The `local` platform, with
its `generic` architecture, is meant for a workstation or laptop.

## Requirements

- bash, git, and a Python 3 for Spack itself;
- internet access where `install.sh` runs, for every step: downloads happen
  during the builds too (Spack sources, Rust crates, …). On Jean Zay, use a
  compilation node with internet access;
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

On Jean Zay, from a compilation node with internet access (a full installation
takes hours: run it inside `tmux` or `screen`, or in a batch job):

```bash
./install.sh --platform jean-zay --arch h100 --project gyselalibxx
. ./activate.sh --platform jean-zay --arch h100 --project gyselalibxx
```

## Installing an environment: `install.sh`

```
./install.sh --platform <site> --arch <arch> --project <project> [options]

  --step <step>            all (default) | spack | env | concretize | install
  --force                  delete and recreate the environment if it already exists
```

The environment is named after `environment-name.txt`, for example
`gyselalibxx-h100-v2026-11-12-0`. The steps run in this order:

| Step | What it does |
|---|---|
| `spack` | clone Spack (`spack-version.txt`) into the platform's prefix, `spack bootstrap now` |
| `env` | (re)create the environment, copy in the project and platform files, `spack repo update`, detect system packages if the platform asks for it |
| `concretize` | concretize, print the specs and the `spack.lock` checksum |
| `install` | build and install |

- **One step at a time:** `--step <step>` runs only that step. This is how to
  resume after a failure, or after a job reached its time limit:
  `--step install` again continues where Spack stopped.
- **No accidental reinstall:** the `env` step (part of a full run) stops if the
  environment of the current version already exists. Pass `--force` to delete
  and recreate it, or bump `version.txt` to build a new one next to it.
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
Tools to `LD_LIBRARY_PATH` when the environment contains it. Activating the
environment also sets the compilers and flags used by the CMake presets
(see below); deactivating it removes them.

In a job script:

```bash
#!/bin/bash
#SBATCH --account=abc@h100
#SBATCH --constraint=h100
#SBATCH --gres=gpu:1

. /path/to/spack-stack/activate.sh --platform jean-zay --arch h100 --project gyselalibxx
srun ./build/my_simulation
```

## Building a project: CMake presets

`cmake/CMakePresets.json` provides the presets `release`, `debug` and `coverage`
(configure, build and test presets). They contain no platform: the compilers
and flags come from environment variables, which each architecture declares in
`platforms/<site>/<arch>/spack/env_vars.yaml` (Spack's
[`env_vars`](https://spack.readthedocs.io/en/latest/env_vars_yaml.html)
section). Spack sets them when the environment is activated, so the same
presets work on every computer.

| Variable | Passed to CMake as |
|---|---|
| `GYSELA_CXX_COMPILER`, `GYSELA_C_COMPILER`, `GYSELA_Fortran_COMPILER` | `CXX`, `CC`, `FC`: the compilers |
| `GYSELA_CXX_FLAGS` | `CXXFLAGS`: initial `CMAKE_CXX_FLAGS` (warnings, compiler workarounds) |
| `GYSELA_CXX_FLAGS_DEBUG` | appended to `CMAKE_CXX_FLAGS_DEBUG` by the `debug` preset |
| `GYSELA_EXE_LINKER_FLAGS` | `LDFLAGS`: initial linker flags (e.g. Cray's GPU-aware MPI library) |

An unset variable keeps CMake's default. Like the other platform files,
`env_vars.yaml` is copied into the environment by the `env` step of
`install.sh`: after changing it, run `./install.sh --step env` again (or edit the
environment's copy in `<environment>/gysela/`). The build type and its flags come
from the preset: `release` (`-O3 -DNDEBUG`), `debug` (`-g -O1`, restart tests
on), `coverage` (`-g -Og --coverage -fprofile-update=atomic`, restart tests on).
Each preset builds in `build/<preset>` with Ninja, and its test preset shows the
output of failing tests.

To use them in a project, include them from its `CMakeUserPresets.json` (not
committed; this needs CMake 3.30 or later, which the environments provide):

```json
{
  "version": 9,
  "include": ["$penv{GYSELA_STACK_ROOT}/cmake/CMakePresets.json"]
}
```

then, after `activate.sh`:

```bash
cmake --preset release
cmake --build --preset release
ctest --preset release
```

Other options are still given on the command line, for example
`cmake --preset debug -DGYSELALIBXX_POISSON_2D_BUILD_TESTING=OFF`.

## Workarounds for Spack limitations

Most of the scripts' logic exists to work around one of these limitations.

**1. Git versions are looked up while concretizing.** A spec such as
`foo@git.<commit>` makes Spack clone the repository during concretization, to
work out which version that commit is. Give the version instead, so that Spack
does not need to: `foo@git.<commit>=<version>`, where `<version>` exists in the
package recipe (for example `py-gysmc@git.f62d…=main`).

**2. `specs:` cannot be included.** Spack includes can carry configuration
(`packages`, `repos`, …) but not the spec list of an environment. Each project
therefore keeps its full `spack.yaml`, and the platform files are attached to
it: `install.sh` copies `platforms/<site>/<arch>/spack/` into
`<environment>/gysela/`, which the projects include. `externals.yaml` is
included by its own name, because a directory include only reads the files
named after a configuration section (`packages.yaml`, `repos.yaml`, …).

**3. Shared installs without `newgrp`/`sg`.** Spack's `permissions:` settings
cover the installed packages, but not its other directories (environments,
repository checkouts, caches). New files also get your primary group rather than
the project's. Since `newgrp` and `sg` are not available, `install.sh` ends by
setting the platform's group (`GYSELA_SPACK_GROUP`) and the group bits on what
you own under the prefix.

**4. Configuration leaking from the user's account.** Every `site.sh` sets
`SPACK_DISABLE_LOCAL_CONFIG=true`, so that `~/.spack` cannot change a build, and
purges the loaded modules. Where `/tmp` is too small for builds (Jean Zay),
`site.sh` points `TMPDIR`, and thus Spack's build stages, to the job's scratch
space. Python's bytecode cache goes to a private per-user directory,
`${TMPDIR:-/tmp}/<user>/pycache` (`PYTHONPYCACHEPREFIX`, set by
`platforms/python-cache.sh`), rather than next to read-only shared installs. It
is private because Python runs a cached `.pyc` that matches its source's size and
date: whoever can write the cache can run code in your Python processes.

**5. Run-time library paths.** Spack does not add packages to
`LD_LIBRARY_PATH` when activating an environment, so `activate.sh` does it for
Kokkos Tools, whose libraries are loaded at run time.

## Adding a platform or an architecture

A platform is a computer (or site); an architecture is a kind of node on it. A
platform has one Spack, shared by all its architectures.

**1. Create `platforms/<site>/site.sh`** (to add only an architecture, skip to
step 2). It is sourced by `install.sh` and `activate.sh`, and must export:

| Variable | Meaning |
|---|---|
| `GYSELA_SPACK_PREFIX` | where Spack is cloned and everything is installed: `<base>/gysela-spack/${GYSELA_SPACK_VERSION}`, with `<base>` typically a project scratch or work space |
| `GYSELA_SPACK_VERSION` | read it from `spack-version.txt`, as the existing `site.sh` files do |
| `GYSELA_SPACK_GROUP` | Unix group the install is shared with |
| `GYSELA_SPACK_JOBS` | build parallelism |
| `SPACK_DISABLE_LOCAL_CONFIG` | `true` |

and optionally:

| Variable | Meaning |
|---|---|
| `GYSELA_DETECT_EXTERNALS` | packages to detect with `spack external find` instead of describing them in `externals.yaml` (`local` uses `gcc`) |

Start from the closest existing `site.sh`. Keep the check that refuses to run it
directly, and guard `module purge` with `command -v module`: `module` may not
exist in non-interactive shells.

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
- **`env_vars.yaml`** (to build projects with the CMake presets): the
  `GYSELA_*` compilers and flags under `env_vars: set:`, as described in
  [Building a project](#building-a-project-cmake-presets). Start from the
  architecture with the closest compiler (GCC, `hipcc` or `nvcc_wrapper`).

An architecture is recognised by its `spack/packages.yaml`; `install.sh` lists
the available ones.

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
      destination: repos/gysela-patches
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

**4. Give git versions their `=<version>` suffix** (see the workarounds above).

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
