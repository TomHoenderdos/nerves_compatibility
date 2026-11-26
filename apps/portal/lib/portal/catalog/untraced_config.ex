defmodule Portal.Catalog.UntracedConfig do
  @moduledoc """
  The compile-time config an untraced firmware build's files depend on that
  its `.app` does not list (stream S11): a firmware build without
  `compile_inputs` (an untraced or unjudged target, a published variant, a
  pinned firmware build) is published with these as extra `compile_env`
  items. A toolchain build's trace lists such reads itself (R5), and so does a
  judged firmware target's (`NccWorker.FirmwareInputs`).

  Each item carries the value the builder's compile read, as
  `Application.fetch_env/2` gave it in the builder's Mix VM: what a user's
  Mix VM reads too when its config leaves the key alone, so a user with no
  config of it matches and one who sets it misses. The client compares
  exactly that (`Precompiled.CompileEnv.lookup/2`).

    * **Logger's keys.** Every `Logger` macro reads `:logger`'s
      `compile_time_purge_matching`, `always_evaluate_messages` and
      `compile_time_purge_level` while its caller compiles. Mix loads
      `:logger` with its `.app` env, which holds `[]` and `false` for the
      first two from Elixir 1.17 to 1.20 and nothing for the third, and the
      worker's firmware project sets none of them. So `{:ok, []}`,
      `{:ok, false}` and `:error`, as R5 records them on every toolchain
      build; only for a build on those Elixir minors.
    * **The package's own keys.** Each `[key]` item R5 wrote in the
      `compile_env` of a toolchain build of the same version, whose read the
      trace names the package as the owner of (`own_keys/2`). A key of an
      app Mix loads before any compile (`:elixir`, `:logger`, `:mix`,
      `:iex`, `:ex_unit`) keeps the value R5 recorded on the build's Elixir
      minor, from a default config variant build; it is left out when no
      such build recorded one or they recorded different ones. A key of
      any other app is unset: the worker's firmware project sets none of
      them, and R5 records a reader of its own app or one in its dependency
      tree as unset, as the client's lookup sees it. One that a default
      build recorded as set is left out rather than contradicted.

  A key the build already lists keeps its own item, and a key of `:nerves`,
  the one app the worker's firmware project configures (the Nerves
  template with `--no-nerves-pack`, and `NccWorker.Project`'s
  `rootfs_type`), is never listed. Left out, a key keeps today's behaviour:
  no check.
  """

  alias Portal.Catalog.ToolchainBuild
  alias Portal.Repo

  @preloaded ~w(elixir logger mix iex ex_unit)
  @builder_config ~w(nerves)
  @logger_minors ~w(1.17 1.18 1.19 1.20)
  @logger [
    {"compile_time_purge_matching", {:ok, []}},
    {"always_evaluate_messages", {:ok, false}},
    {"compile_time_purge_level", :error}
  ]

  @typedoc """
  A version's own keys: `{app, key} => %{minor => values}`, `values` the
  set of recorded values a default config variant build on that Elixir
  minor wrote (`:none` from a named variant only).
  """
  @type own :: %{{String.t(), String.t()} => %{String.t() => MapSet.t(String.t()) | :none}}

  @doc """
  `env` (a firmware build's `compile_env`, with its own items first) with
  the items above added, for a build on Elixir `elixir` with the version's
  `own` keys. `opts`: `:logger` and `:own` (both default true), the two
  switches.
  """
  @spec items([map()], String.t() | nil, own(), keyword()) :: [map()]
  def items(env, elixir, own, opts \\ []) when is_list(env) do
    logger? = Keyword.get(opts, :logger, true)
    own? = Keyword.get(opts, :own, true)
    minor = minor(elixir)

    logger =
      if logger? and minor in @logger_minors,
        do: for({key, value} <- @logger, do: {{"logger", key}, encode(value)}),
        else: []

    own_items =
      if own?,
        do:
          for(
            {{app, _key} = name, by_minor} <- Enum.sort(own),
            app != "logger" or logger?,
            value = own_value(app, Map.get(by_minor, minor)),
            value != nil,
            do: {name, value}
          ),
        else: []

    # R5's own record of a Logger key wins over the `.app` table.
    recorded = Map.new(own_items)
    listed = MapSet.new(env, &{&1["app"], &1["path"]})

    added =
      (Enum.map(logger, fn {name, value} -> {name, Map.get(recorded, name, value)} end) ++
         Enum.reject(own_items, fn {name, _} -> List.keymember?(logger, name, 0) end))
      |> Enum.reject(fn {{app, key}, _value} ->
        app in @builder_config or MapSet.member?(listed, {app, [key]})
      end)
      |> Enum.map(fn {{app, key}, value} ->
        %{"app" => app, "path" => [key], "value" => value}
      end)

    env ++ added
  end

  # A preloaded app's key: the one value a default build on the minor
  # recorded. Any other app's: unset, unless a default build recorded it as
  # set.
  defp own_value(app, values) when app in @preloaded do
    case values do
      %MapSet{} -> if MapSet.size(values) == 1, do: Enum.at(values, 0)
      _ -> nil
    end
  end

  defp own_value(_app, values) do
    unset = encode(:error)

    case values do
      %MapSet{} -> if Enum.all?(values, &(&1 == unset)), do: unset
      _ -> unset
    end
  end

  @own_keys_sql """
  WITH apps AS (
    SELECT $2::text AS app
    UNION
    SELECT DISTINCT substring(f->>'path' FROM '^ebin/([^/]+)\\.app$')
    FROM catalog_toolchain_builds t
    CROSS JOIN LATERAL jsonb_array_elements(
      CASE WHEN jsonb_typeof(t.file_manifest->'ebin') = 'array' THEN t.file_manifest->'ebin'
           ELSE '[]'::jsonb END) AS f
    WHERE t.package_id = $1 AND f->>'path' ~ '^ebin/[^/]+\\.app$'
  )
  SELECT DISTINCT t.version, ce->>'app', ce->'path'->>0, t.elixir,
         coalesce(t.config_variant, 'default') = 'default', ce->>'value'
  FROM catalog_toolchain_builds t
  CROSS JOIN LATERAL unnest(t.compile_env) AS ce
  WHERE t.package_id = $1 AND t.variant IN #{ToolchainBuild.variants_sql()}
    AND t.compile_env_rule = 1
    AND jsonb_typeof(ce->'path') = 'array' AND jsonb_array_length(ce->'path') = 1
    AND jsonb_typeof(ce->'path'->0) = 'string' AND jsonb_typeof(ce->'app') = 'string'
    AND jsonb_typeof(ce->'value') = 'string'
    AND jsonb_typeof(t.compile_observations->'config_reads') = 'array'
    AND EXISTS (
      SELECT 1 FROM jsonb_array_elements(t.compile_observations->'config_reads') AS e
      WHERE e->>'owner' IN (SELECT app FROM apps) AND e->'arg'->>'app' = ce->>'app'
        AND e->'arg'->>'key' = ce->'path'->>0)
  """

  @doc """
  The package's own keys by version (`%{version => own()}`): from each
  toolchain build of the package (a listed variant) whose `compile_env` R5
  wrote (`compile_env_rule` 1), the `[key]` items whose read its trace
  names the package as the owner of (`compile_observations.config_reads`),
  by the package's Hex name or by an app name its builds' ebin lists
  (`ebin/<app>.app`). The toolchain rows are in the package's fingerprint
  (`Portal.Catalog`, by `xmin`).
  """
  @spec own_keys(term(), String.t()) :: %{String.t() => own()}
  def own_keys(package_id, package_name) do
    group(Repo.query!(@own_keys_sql, [Ecto.UUID.dump!(package_id), package_name]).rows)
  end

  @doc false
  # `own_keys/2`'s rows (`[version, app, key, elixir, default?, value]`) by
  # version.
  @spec group([list()]) :: %{String.t() => own()}
  def group(rows) do
    rows
    |> Enum.reduce(%{}, fn [version, app, key, elixir, default?, value], acc ->
      update_in(acc, [Access.key(version, %{}), Access.key({app, key}, %{})], fn by_minor ->
        Map.update(by_minor, minor(elixir), entry(default?, value), &merge(&1, default?, value))
      end)
    end)
  end

  defp entry(true, value), do: MapSet.new([value])
  defp entry(false, _value), do: :none

  defp merge(:none, default?, value), do: entry(default?, value)
  defp merge(set, true, value), do: MapSet.put(set, value)
  defp merge(set, false, _value), do: set

  defp minor(elixir) when is_binary(elixir) do
    case String.split(elixir, ".") do
      [major, minor | _] -> major <> "." <> minor
      _ -> nil
    end
  end

  defp minor(_elixir), do: nil

  defp encode(term),
    do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)
end
