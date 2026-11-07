# The tracer's loaded-library check reads /proc/self/maps, which only Linux
# has. Elsewhere (a developer's macOS) the fixture suites waive it; the
# worker never sets this (NccWorker.Portability.MappedLibs).
unless File.exists?("/proc/self/maps"),
  do: System.put_env("NCC_TRACE_ALLOW_NO_NIF_CHECK", "1")

# Tests tagged :integration need Hex.pm (and real package builds); they run
# only through `make test-integration` or `make test-portability-goldens`.
ExUnit.start(exclude: [:integration])
