defmodule Portal.UpstreamBackfill do
  @moduledoc """
  Seeds the scan queue from the package list published by the upstream
  compatibility site.

  The upstream site has no JSON API; its `/packages` page ships the whole table
  as a `const ROWS = [...]` literal in a `<script>` block, so one request yields
  every package it has scanned. A second literal, `PLACEHOLDERS`, holds packages
  it knows about but has not scanned; those are excluded by default.

  Enqueueing is deliberately indirect. Turning a package name into a build means
  asking hex.pm for its latest version, and doing that for ~2850 packages in one
  pass would both hammer hex.pm and lose all progress on the first network
  hiccup. Instead each package gets its own `Portal.Workers.Backfill` job in the
  `intake` queue, staggered one per second so the sweep stays under hex.pm's
  rate limit, and retried individually when it fails.
  """

  require Logger

  alias Portal.Workers.Backfill

  @upstream_url "https://compatibility.embedded-elixir.com/packages"

  @doc """
  Fetch the upstream list and enqueue a `Backfill` job per package.

  Options:

    * `:include_placeholders` - also enqueue packages upstream lists but has not
      scanned (default `false`)
    * `:stagger_ms` - spacing between jobs (default `1000`)
    * `:limit` - only enqueue the first N packages, for a dry run
  """
  @spec run(keyword()) :: {:ok, %{fetched: non_neg_integer(), enqueued: non_neg_integer()}}
  def run(opts \\ []) do
    with {:ok, names} <- fetch_package_names(opts) do
      names = maybe_limit(names, Keyword.get(opts, :limit))
      stagger_ms = Keyword.get(opts, :stagger_ms, 1000)

      enqueued =
        names
        |> Enum.with_index()
        |> Enum.reduce(0, fn {name, index}, acc ->
          job = Backfill.new(%{package: name}, schedule_in: div(index * stagger_ms, 1000))

          case Oban.insert(job) do
            {:ok, _job} ->
              acc + 1

            {:error, reason} ->
              Logger.warning("Backfill enqueue failed for #{name}: #{inspect(reason)}")
              acc
          end
        end)

      Logger.info("Upstream backfill: #{enqueued} of #{length(names)} packages enqueued")
      {:ok, %{fetched: length(names), enqueued: enqueued}}
    end
  end

  @doc """
  Package names published upstream, sorted and deduplicated.
  """
  @spec fetch_package_names(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def fetch_package_names(opts \\ []) do
    case Req.get(@upstream_url, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: html}} when is_binary(html) ->
        scanned = extract_names(html, "ROWS")

        placeholders =
          if Keyword.get(opts, :include_placeholders, false) do
            extract_names(html, "PLACEHOLDERS")
          else
            []
          end

        case Enum.uniq(scanned ++ placeholders) do
          [] -> {:error, :no_packages_found}
          names -> {:ok, Enum.sort(names)}
        end

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Pull the package names out of one `const <name> = [...]` literal.

  Each literal sits on a single line ending in `];`, so anchoring the match to
  one line keeps a `];` inside a package description from truncating it.
  """
  @spec extract_names(String.t(), String.t()) :: [String.t()]
  def extract_names(html, const) do
    case Regex.run(~r/const #{const} = (\[.*\]);$/m, html) do
      [_, json] ->
        json
        |> Jason.decode!()
        |> Enum.map(& &1["name"])
        |> Enum.filter(&(is_binary(&1) and &1 != ""))

      _ ->
        Logger.warning("Upstream page has no #{const} literal")
        []
    end
  end

  defp maybe_limit(names, nil), do: names
  defp maybe_limit(names, limit) when is_integer(limit), do: Enum.take(names, limit)
end
