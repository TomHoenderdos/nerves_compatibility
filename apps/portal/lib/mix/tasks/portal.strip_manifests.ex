defmodule Mix.Tasks.Portal.StripManifests do
  @shortdoc "Strip stored dependency file manifests out of catalog_system_results"
  @moduledoc """
  #{@shortdoc}.

      mix portal.strip_manifests --dry-run
      mix portal.strip_manifests --batch-size 500

  In production there is no Mix; call the module directly instead:

      bin/portal eval 'Portal.Catalog.ManifestBackfill.run(dry_run: true)'

  See `Portal.Catalog.ManifestBackfill` for what this removes and why the disk
  it frees is not returned to the filesystem without a separate `VACUUM FULL`.
  """
  use Mix.Task

  alias Portal.Catalog.ManifestBackfill

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args, strict: [dry_run: :boolean, batch_size: :integer])

    {:ok, report} = ManifestBackfill.run(opts)

    verb = if report.dry_run, do: "would strip", else: "stripped"
    Mix.shell().info("#{verb} #{report.rows} rows (#{report.manifest_bytes} bytes of manifests)")
  end
end
