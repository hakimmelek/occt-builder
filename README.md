# occt-builder

Build **Open CASCADE Technology (OCCT)** once, from the official sources, for
**any OCCT version**, with a single double-click. Then build OCCTools (and any
other project) against the result, without ever recompiling OCCT.

```
downloads/  ──►  sources/ + third_party/  ──►  build_occt.bat  ──►  install/occt-7.9.2-vc143-x64/
 (you drop       (extracted                    (reads                (DLLs, .lib, headers,
  archives)       automatically)                occt-build.yaml)      CMake config, build info)
```

`occt-builder` is self-contained and has no hard-coded paths: everything is
resolved relative to this folder, so it can be cloned, copied or moved
anywhere. A build folder left over from another location is detected and
re-configured automatically.

---

## 1. Folder structure

```
occt-builder/
├── build_occt.bat          ← double-click (Windows)
├── build_occt.sh           ← same on Linux/macOS (needs PowerShell 7 "pwsh")
├── occt-build.yaml         ← THE configuration file (commented)
├── scripts/
│   ├── Build-Occt.ps1      ← the build logic
│   └── YamlLite.ps1        ← small YAML reader (no extra module needed)
├── downloads/
│   ├── occt/               ← drop OCCT source archives here
│   └── 3rdparty/           ← drop third-party archives here
├── sources/                ← extracted OCCT sources, one folder per version
├── third_party/            ← extracted third-party libraries (OCCT 3RDPARTY_DIR)
├── build/                  ← CMake build trees        (generated, can be deleted)
├── install/                ← final OCCT installations (generated, keep these)
└── logs/                   ← one log file per build   (generated)
```

Only the scripts, the YAML and the README files are committed to git;
downloads, sources, builds and installs stay on your machine.

## 2. Prerequisites (Windows)

| What | Why | Notes |
|------|-----|-------|
| **Visual Studio 2019 or 2022** (Community is fine) with the workload **"Desktop development with C++"** | Compiler | The builder finds it automatically (`vswhere`). The workload includes CMake. |
| **CMake** (OCCT needs ≥ 3.10; use a recent one) | Build system | Optional: Visual Studio's bundled CMake is used if none is on `PATH`. |
| PowerShell | Runs the script | Built into Windows. PowerShell 7 (`pwsh`) is used if installed. |
| 7-Zip | Only for `.7z` archives | `.zip` and `.tar.gz` are extracted with Windows' built-in `tar`. |
| ~10 GB free disk per configuration | Build tree | The install folder itself is a few hundred MB. |

## 3. Step by step

### Step 1 — Download the OCCT sources

Get the **source code** of the version you want:

- GitHub releases: <https://github.com/Open-Cascade-SAS/OCCT/releases>
  → "Source code (zip)" of e.g. `V7_9_2` or `V8_0_1`
- or <https://dev.opencascade.org/release>

Put the archive in `downloads/occt/` (or extract it yourself into `sources/`,
or `git clone` there).

### Step 2 — Download the third-party libraries

On Windows, OCCT needs at least **FreeType** (text rendering in the
Visualization module, which STEP/XCAF depends on).

- Easiest: the prebuilt **3rd-party bundle for Visual Studio** from
  <https://dev.opencascade.org/resources/download/3rd-party-components>
  (FreeType, Tcl/Tk, TBB, RapidJSON, FreeImage, …), or the 3rd-party archive
  attached to the GitHub release if there is one.
- Or each library individually (e.g. FreeType only).

Put the archives in `downloads/3rdparty/` (or extract them into
`third_party/`). You should end up with:

```
third_party/
├── freetype-2.13.3-x64/     (contains include/, lib/, bin/)
├── tcltk-8.6.15-x64/        (only if you build Draw)
└── ...
```

A single wrapper folder such as `third_party/3rdparty-vc14-64/freetype-…` is
detected automatically.

> **Linux:** skip this step and install the system packages instead
> (Ubuntu: `sudo apt install build-essential cmake ninja-build libfreetype-dev
> libfontconfig-dev libgl-dev libx11-dev`). For headless rendering on a
> server, also `xvfb` and Mesa (`libgl1-mesa-dri`).

### Step 3 — Review `occt-build.yaml`

The defaults already build what OCCTools needs (Release DLLs, modules up to
DataExchange, FreeType + OpenGL). The settings you will most likely touch:

```yaml
occt:
  version: "7.9.2"            # which source folder to use, if you have several
build:
  configurations: [Release]   # add Debug to debug into OCCT
features:
  tbb: false                  # turn on optional libraries here
modules:
  Draw: false                 # true to get DRAWEXE (needs Tcl/Tk)
```

Every option is documented in the file itself.

### Step 4 — Double-click `build_occt.bat`

The window shows each step. The first build takes **20–60 min** depending on
your CPU. At the end you get:

```
==> Done: OCCT 7.9.2 installed in ...\occt-builder\install\occt-7.9.2-vc143-x64
    Use from CMake: -DOpenCASCADE_DIR=.../install/occt-7.9.2-vc143-x64/cmake
```

Useful variants (from a terminal):

```bat
build_occt.bat -DryRun              :: show resolved settings and CMake commands, build nothing
build_occt.bat -Clean               :: wipe the build folder and rebuild from scratch
build_occt.bat configs\debug.yaml   :: use another configuration file
```

Running it again only recompiles what changed.

## 4. What you get

```
install/occt-7.9.2-vc143-x64/
├── win64/vc14/bin/          ← TK*.dll (+ FreeType DLLs, copied when install_dlls: true)
├── win64/vc14/bind/         ← debug DLLs, if Debug was built
├── win64/vc14/lib/          ← import libraries (.lib)
├── inc/                     ← headers
├── cmake/                   ← OpenCASCADEConfig.cmake  (for find_package)
├── env.bat                  ← OCCT's own environment script
├── occt-env.bat             ← adds the DLL folders to PATH (generated by occt-builder)
└── occt-build-info.json     ← what was built, how, and where (generated by occt-builder)
```

`occt-build-info.json` records the OCCT version, compiler, configurations,
every CMake option used, the CMake config folder and the DLL folders. Tools and
scripts read this file instead of guessing paths. It holds no absolute paths:
`cmake_dir` and `bin_dirs` are relative to the install folder (where the file
lives), the other paths relative to the occt-builder folder. `occt-env.bat`
also locates itself, so an install folder still works after being moved or
copied to another machine.

## 5. Several OCCT versions side by side

Each version/compiler combination gets its own folder, named by
`output.name` (`occt-{version}-{compiler}-{arch}` by default):

```
install/
├── occt-7.8.1-vc143-x64/
├── occt-7.9.2-vc143-x64/
└── occt-8.0.1-vc143-x64/
```

To build another version: drop its sources, set `occt.version` (or
`occt.source`) and run again. Previous installs are untouched.

## 6. Any OCCT version: how it stays generic

- **Version detection** reads `adm/cmake/version.cmake` (or
  `Standard_Version.hxx` for old releases); nothing is hard-coded.
- **Generic option mapping**: a module `X` becomes `BUILD_MODULE_X`, a
  feature `foo` becomes `USE_FOO` / `INSTALL_FOO` / `3RDPARTY_FOO_DIR`. These
  names have been stable across OCCT 7.x and 8.x.
- **`cmake_options`** passes any raw `-DNAME=VALUE`, for options a given
  version adds or renames.
- **`version_overrides`** applies settings only to matching versions:

  ```yaml
  version_overrides:
    "7.*":
      cmake_options:
        BUILD_MODULE_DETools: OFF
    "8.0.*":
      features:
        tbb: true
  ```

Unknown options are ignored by CMake (it only prints a warning), so one config
file can serve several OCCT versions.

## 7. Using the build from another project (OCCTools)

CMake:

```bat
cmake -S . -B build -DOpenCASCADE_DIR=<occt-builder>/install/occt-7.9.2-vc143-x64/cmake
```

```cmake
find_package(OpenCASCADE CONFIG REQUIRED)
target_link_libraries(my_tool PRIVATE TKDESTEP TKXCAF TKBRep TKTopAlgo TKMath TKernel)
```

At runtime, the DLL folder must be on `PATH` (run `occt-env.bat` first, or
copy the DLLs next to your executable).

## 8. Troubleshooting

| Problem | Fix |
|---------|-----|
| `No OCCT sources found` | Put the archive in `downloads/occt/` or a source folder in `sources/`. |
| `Several OCCT source folders found` | Set `occt.version: "7.9.2"` (or `occt.source`). |
| CMake error about **FreeType** | Check `third_party/` contains a `freetype*` folder with `include/` and `lib/`, or set `third_party.paths.freetype`. |
| `Visual Studio ... not found` | Install the "Desktop development with C++" workload. |
| Errors about path length / files not found deep in `build/` | Use short folders: `output.build_root: D:/occt/build`, `output.install_root: D:/occt/install`, or enable Windows long paths. |
| Build is very slow | Exclude the `build/` folder from antivirus real-time scanning; check `toolchain.jobs: 0`. |
| A build failed half-way | Read the log in `logs/` (the last error is usually the real one), fix it, run again; use `-Clean` if CMake settings changed a lot. |
| Script blocked by execution policy | Always start through `build_occt.bat` (it uses `-ExecutionPolicy Bypass`). |
| The window closes too fast | It pauses at the end; set `OCCT_BUILDER_NOPAUSE=1` only for automated runs. |

## 9. Linux / macOS

Same configuration file, same folders:

```sh
./build_occt.sh             # needs pwsh (PowerShell 7) installed
./build_occt.sh -DryRun
```

Ninja is used if available, otherwise Unix Makefiles. Install folders are
named with the compiler, e.g. `occt-7.9.2-gcc13-x64`.
