defmodule Portal.Catalog do
  @moduledoc """
  Ash domain for compatibility data.

  Holds the package catalog, scan runs, per-system results, content-addressed
  build artifacts, and admin-editable package overrides. Populated by the
  builder Oban worker (Phase 3); read by the public LiveView/JSON surface.
  """

  use Ash.Domain

  resources do
    resource(Portal.Catalog.Package)
    resource(Portal.Catalog.Run)
    resource(Portal.Catalog.SystemResult)
    resource(Portal.Catalog.Artifact)
    resource(Portal.Catalog.PackageOverride)
  end
end
