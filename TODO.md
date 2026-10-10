# TODO

Open gaps. Everything else that used to be listed here is done.

1. Warn on the package page when a package writes into its own source directory during the build. The worker detects it (`NccWorker.SourceScanner`, emitted as `source_changes`), but `Portal.Catalog` neither stores nor shows it.
1. Detect and flag build results that differ between Nerves systems in a way that points at the build rather than the package.
1. When a package writes into its source directory, retry with clean `_build` and `deps` directories; many such packages would then build.
