defmodule Compatibility.Pins do
  @moduledoc """
  A pin set: a package version's exact dependency closure from a project's
  `mix.lock`, which a pinned build compiles the package against
  (lock-driven builds spec, sections 1 and 3).

  The set is JSON-shaped, as the portal sends it in `NCC_INPUT.pins` and
  stores it on `Portal.Catalog.PinnedBuild`:

      %{"hash" => "<64 hex>", "package_checksum" => "<64 hex>",
        "deps" => [%{"name", "hex", "version", "checksum"}]}

  `deps` is the closure without the package itself, in the form of a build's
  `deps_lock`: `name` is the lock key (the application), `hex` the Hex
  package. `hash/1` names the set, and both the worker and the portal compute
  it here. `validate/3` is the one check of a set, run by the worker before
  anything else (`NccWorker.CLI`) and by the portal before it queues one.
  `compare/2` is the exact check of a resolved lock against the set.
  """

  @max_deps 200
  @max_name_bytes 64
  @name ~r/\A[a-z][a-z0-9_]*\z/
  @checksum ~r/\A[0-9a-f]{64}\z/
  @dev_only ~w(lazy_html floki ex_doc earmark earmark_parser makeup makeup_elixir makeup_erlang
               credo dialyxir excoveralls mix_test_watch stream_data benchee mox bypass)

  @type dep :: %{String.t() => String.t()}
  @type t :: %{String.t() => term()}
  @type diff :: %{extra: [String.t()], missing: [String.t()], differing: [String.t()]}

  @doc "The most dependencies one set may pin."
  @spec max_deps() :: pos_integer()
  def max_deps, do: @max_deps

  @doc """
  Packages a project locks for its tests or docs only (`only: :test`, which
  a lock cannot say). An optional edge into one is not followed when a set is
  derived: a wrong guess wastes one build and never serves a wrong one.
  """
  @spec dev_only() :: [String.t()]
  def dev_only, do: @dev_only

  @doc """
  Nerves tooling, which no set may pin: `nerves`, `nerves_bootstrap`, every
  `nerves_system_*` and every `nerves_toolchain_*`.
  """
  @spec tooling?(term()) :: boolean()
  def tooling?(name) when name in ["nerves", "nerves_bootstrap"], do: true
  def tooling?("nerves_system_" <> _), do: true
  def tooling?("nerves_toolchain_" <> _), do: true
  def tooling?(_name), do: false

  @doc """
  The set's name: the lowercase hex sha256 over `"pkg version checksum\\n"`
  followed by the sorted `"name version checksum\\n"` lines of `deps`.
  """
  @spec hash(%{
          package: String.t(),
          version: String.t(),
          package_checksum: String.t(),
          deps: [dep()]
        }) ::
          String.t()
  def hash(%{package: package, version: version, package_checksum: checksum, deps: deps}) do
    lines =
      deps
      |> Enum.map(&"#{&1["name"]} #{&1["version"]} #{&1["checksum"]}\n")
      |> Enum.sort()

    :sha256
    |> :crypto.hash(["#{package} #{version} #{checksum}\n" | lines])
    |> Base.encode16(case: :lower)
  end

  @doc """
  Checks a set for `package` at `version`: at most #{@max_deps} deps, names
  (lock key and Hex package) matching `^[a-z][a-z0-9_]*$` within
  #{@max_name_bytes} bytes, versions that parse, checksums of 64 lowercase
  hex, no duplicate name, no Nerves tooling (`tooling?/1`), not the package
  itself, and a `hash` that recomputes. `{:ok, pins}` as given, or
  `{:error, {:invalid_pins, why}}`.
  """
  @spec validate(String.t(), String.t(), term()) :: {:ok, t()} | {:error, {:invalid_pins, term()}}
  def validate(
        package,
        version,
        %{"hash" => hash, "package_checksum" => checksum, "deps" => deps} = pins
      )
      when is_binary(hash) do
    with :ok <- check_list(deps),
         :ok <- check_checksum(checksum),
         :ok <- check_deps(deps, package),
         :ok <- check_hash(hash, package, version, checksum, deps) do
      {:ok, pins}
    else
      {:error, why} -> {:error, {:invalid_pins, why}}
    end
  end

  def validate(_package, _version, _pins), do: {:error, {:invalid_pins, :not_a_map}}

  defp check_list(deps) when not is_list(deps), do: {:error, :deps_not_a_list}
  defp check_list(deps) when length(deps) > @max_deps, do: {:error, {:too_many, length(deps)}}
  defp check_list(_deps), do: :ok

  defp check_deps(deps, package) do
    Enum.reduce_while(deps, {:ok, MapSet.new()}, fn dep, {:ok, seen} ->
      case check_dep(dep, package, seen) do
        :ok -> {:cont, {:ok, MapSet.put(seen, dep["name"])}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      error -> error
    end
  end

  defp check_dep(
         %{"name" => name, "hex" => hex, "version" => version, "checksum" => sum},
         package,
         seen
       ) do
    cond do
      not valid_name?(name) ->
        {:error, {:name, name}}

      not valid_name?(hex) ->
        {:error, {:name, hex}}

      not (is_binary(version) and match?({:ok, _}, Version.parse(version))) ->
        {:error, {:version, version}}

      check_checksum(sum) != :ok ->
        {:error, {:checksum, sum}}

      MapSet.member?(seen, name) ->
        {:error, {:duplicate, name}}

      tooling?(name) or tooling?(hex) ->
        {:error, {:tooling, name}}

      name == package or hex == package ->
        {:error, {:package_itself, name}}

      true ->
        :ok
    end
  end

  defp check_dep(dep, _package, _seen), do: {:error, {:dep, dep}}

  defp check_checksum(sum) do
    if is_binary(sum) and Regex.match?(@checksum, sum), do: :ok, else: {:error, {:checksum, sum}}
  end

  defp check_hash(hash, package, version, checksum, deps) do
    recomputed =
      hash(%{package: package, version: version, package_checksum: checksum, deps: deps})

    if recomputed == hash, do: :ok, else: {:error, :hash_mismatch}
  end

  defp valid_name?(name),
    do: is_binary(name) and byte_size(name) <= @max_name_bytes and Regex.match?(@name, name)

  @doc """
  The `deps_lock` shape of a set's `deps`: `%{name => %{"version", "checksum"}}`.
  """
  @spec to_lock([dep()]) :: %{String.t() => %{String.t() => String.t()}}
  def to_lock(deps),
    do: Map.new(deps, &{&1["name"], %{"version" => &1["version"], "checksum" => &1["checksum"]}})

  @doc """
  The exact check of `locked`, a resolved closure in the `deps_lock` shape
  (`nil` for a lock that could not be read), against a set's `deps`: `:ok`
  when the names, versions and outer checksums are the same, else
  `{:mismatch, reason, diff}`. `diff` names the dependencies the lock has
  beyond the set (`extra`), the set's it lacks (`missing`) and those it holds
  at another version or checksum (`differing`), each sorted. `reason` is
  `"pins_checksum_mismatch"` when only checksums differ, else
  `"pins_closure_mismatch"`.
  """
  @spec compare([dep()], map() | nil) :: :ok | {:mismatch, String.t(), diff()}
  def compare(deps, locked) when not is_map(locked), do: compare(deps, %{})

  def compare(deps, locked) do
    want = to_lock(deps)
    extra = locked |> Map.keys() |> Enum.reject(&Map.has_key?(want, &1)) |> Enum.sort()
    missing = want |> Map.keys() |> Enum.reject(&Map.has_key?(locked, &1)) |> Enum.sort()

    differing =
      for {name, entry} <- want, Map.has_key?(locked, name), locked[name] != entry, do: name

    diff = %{extra: extra, missing: missing, differing: Enum.sort(differing)}

    cond do
      extra == [] and missing == [] and differing == [] ->
        :ok

      extra == [] and missing == [] and
          Enum.all?(differing, &(locked[&1]["version"] == want[&1]["version"])) ->
        {:mismatch, "pins_checksum_mismatch", diff}

      true ->
        {:mismatch, "pins_closure_mismatch", diff}
    end
  end

  @doc """
  A refusal's reason with the dependencies it names, as
  `"reason (+extra -missing ~differing)"`; the reason alone when it names none.
  """
  @spec describe(String.t(), diff()) :: String.t()
  def describe(reason, %{extra: extra, missing: missing, differing: differing}) do
    names =
      Enum.map(extra, &("+" <> &1)) ++
        Enum.map(missing, &("-" <> &1)) ++ Enum.map(differing, &("~" <> &1))

    if names == [], do: reason, else: "#{reason} (#{Enum.join(names, " ")})"
  end
end
