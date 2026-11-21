# The tracer's loaded-library check reads /proc/self/maps, which only Linux
# has. Elsewhere (a developer's macOS) the fixture suites waive it; the
# worker never sets this (NccWorker.Portability.MappedLibs).
unless File.exists?("/proc/self/maps"),
  do: System.put_env("NCC_TRACE_ALLOW_NO_NIF_CHECK", "1")

# The judge's download of declared-absent dependencies
# (NccWorker.Portability.Declared.fetch/4) stays off: fixtures lay out the
# Hex cache they judge from. The goldens integration test turns it on.
System.put_env("NCC_DECLARED_FETCH", "0")

# Tests tagged :integration need Hex.pm (and real package builds); they run
# only through `make test-integration` or `make test-portability-goldens`.
ExUnit.start(exclude: [:integration])
