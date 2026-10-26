defmodule Mix.Tasks.Portal.BuildCache.Push do
  @shortdoc "Push the local build cache into L2"
  @moduledoc """
  Uploads every local build cache entry that the L2 bucket lacks. Resumable
  (run it again to carry on) and bounded.

      mix portal.build_cache.push --dry-run
      mix portal.build_cache.push --slug sha256_abc --limit 500 --max-gb 5

  Options: `--root DIR` (default `NCC_BUILD_CACHE`), `--slug SLUG`,
  `--limit N` entries, `--max-gb GB` uploaded, `--dry-run`.

  On a deployed host, where Mix is not available, the same runs as

      bin/portal eval 'Portal.BuildCache.L2.Push.run(limit: 500) |> IO.inspect()'
  """
  use Mix.Task
  alias Portal.BuildCache.L2.Push

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [root: :string, slug: :string, limit: :integer, max_gb: :float, dry_run: :boolean]
      )

    Mix.Task.run("app.config")

    push_opts =
      opts
      |> Keyword.take([:root, :slug, :limit, :dry_run])
      |> put_max_bytes(opts[:max_gb])

    case Push.run(push_opts) do
      {:ok, _summary} -> :ok
      {:error, msg} -> Mix.raise(msg)
    end
  end

  defp put_max_bytes(opts, nil), do: opts
  defp put_max_bytes(opts, gb), do: Keyword.put(opts, :max_bytes, round(gb * 1024 * 1024 * 1024))
end
