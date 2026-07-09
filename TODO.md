# TODO

1. Detect and report NIF implementation language per package. Signal seen so
   far: `rustler` / `rustler_precompiled` / `cargo` / `.rs` / `rustc` → Rust;
   `zigler` / `zigler_precompiled` / `.zig` → Zig; `.c` / `c_src` / `Makefile`
   / `gcc` / `clang` → C. Useful both on its own (NIF-language distribution
   across the ecosystem) and for failure-cluster attribution (e.g. "Rust
   packages fail on riscv64 because no RustlerPrecompiled target exists").
1. Store priv files naming them by their SHA256

1. Detect whether the package changes its source directory. Do this by capturing the directory tree before and after for the package under the `deps` directory. On the package page, report the change and show a warning that changing the source directory when compiling can cause failures when switching mix targets.
1. Check whether differences when compiled on different Nerves systems
1. If a package changes its source directory, remove the `_build` and `deps` directories and rebuild. This should get a lot of packages building. This may affect the loader since the loader isn't going to put the build products in src directories.

## Done

1. Keep manifest of priv files with SHA256 sums of each
1. Record how long that it takes to run the compatibility check for each package. Show discretely on package info page at the bottom.
1. Detect whether package compiles deterministically or not
1. On each package's page, show the pass/fail/unknown compatibility status of each of that package's dependencies
1. Add a way to prioritize a list of packages to check. Add `circuits_gpio`, `circuits_i2c`, `circuits_spi`, `circuits_uart`, `vintage_net`, `vintage_net_wifi`, and other commonly used Nerves packages to it.
1. ✅ Fix log links on package pages so they resolve through the Phoenix-served site and API.
1. ✅ Add a way to skip a package based on whether it has a dependency. Skip all packages that depend on `:nerves_system_br` or `:nerves_toolchain_ctng`.
1. ✅ Change the main page to provide a summary of the packages checked. Include top ten lists of the most recently checked passing packages, most recently checked failing packages.
1. If a package/version has been marked as retired in hex.pm, mark it as skipped with a reason that it was retired on hex.pm.
1. Update the package page to include footprint info per Nerves system in addition to the averaged footprint info
1. Detect whether the package uses ports by looking for calls to `Port.open/2`, `System.cmd/2`, `System.cmd/3`, `:os.cmd/1`, `:os.cmd/2`, `System.shell/1`, `System.shell/2`
1. Detect whether the package is an application or library. I.e., does it provide an Application.start callback in its .app file or not.
1. Detect whether the package provides a NIF. This is detected by looking for a call to `:erlang.load_nif/2` in a BEAM file.
1. Detect whether the package uses the Application environment.
1. Detect BEAM languages used in the package. Base this on file extensions for now. Check for at least Erlang, Elixir, Gleam.
1. Detect whether a package calls the shell. Look for calls to `System.shell`, `:os.cmd`.
