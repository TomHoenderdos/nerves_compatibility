defmodule Compatibility.ForeignPriv do
  @moduledoc """
  Foreign priv builds (foreign priv spec, 2026-11-20): a package whose
  compile writes files into another closure member's build `priv`, for one
  reviewed pattern only, kino's `Kino.JS`, which packs each module's assets
  into `<kino priv>/assets/<D(M)>/<hash>.tar.gz`. Shared by the worker's
  judge (`NccWorker.Portability.ForeignPriv`) and the portal's ingest
  (`Portal.Catalog.ToolchainForeignPriv`); the client keeps its own copy of
  the table.

  `rules/0` is the reviewed table: one entry per kino release whose
  `lib/kino/js.ex` was read, with that file's sha256 and the three call
  sites (module, function, arity, line) whose calls the judge accepts. Any
  other kino release, or the same release with other bytes, has no rule,
  and its writers are refused as before.

  An entry of a build's `foreign_priv` list is
  `%{"app" => "kino", "path" => "priv/assets/<d>/<h>.tar.gz", "sha256",
  "size", "mode" => 33188, "module", "assets_path"}`: `d` is `dir_name/1`
  of `module`, `h` 26 characters of `[a-z2-7]`, the path relative to kino's
  build dir. `check_entries/3` is the shape check both sides run before
  anything is read.
  """

  alias Compatibility.StaticPriv

  @target "kino"
  @max_entries 64
  @max_bytes 10 * 1024 * 1024
  @max_inflated 64 * 1024 * 1024
  @mode 0o100644
  @path ~r/\Apriv\/assets\/([A-Z][A-Za-z0-9_]*)\/([a-z2-7]{26})\.tar\.gz\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @manifest_keys ["app", "path", "sha256", "size", "mode"]

  @rules [
    %{
      id: "kino_js_v1",
      target: "kino",
      version: "0.19.1",
      js_sha256: "e65c8f611e5e7a55a7088345ef7e3029348655b94874bca4222cd9f78f3289c6",
      rm_rf: {"Elixir.Kino.JS", "MACRO-__before_compile__", 2, 368},
      mkdir_p: {"Elixir.Kino.JS", "MACRO-__before_compile__", 2, 369},
      archive: {"Elixir.Kino.JS", "package_assets!", 2, 435}
    }
  ]

  @type frame :: {String.t(), String.t(), non_neg_integer(), pos_integer()}
  @type rule :: %{
          id: String.t(),
          target: String.t(),
          version: String.t(),
          js_sha256: String.t(),
          rm_rf: frame(),
          mkdir_p: frame(),
          archive: frame()
        }

  @doc "The one app another package's compile may write into: kino."
  @spec target() :: String.t()
  def target, do: @target

  @spec rules() :: [rule()]
  def rules, do: @rules

  @doc "The reviewed rule named `id`, else nil."
  @spec rule(term()) :: rule() | nil
  def rule(id), do: Enum.find(@rules, &(&1.id == id))

  @doc "The rule reviewed for kino `version` whose `lib/kino/js.ex` is exactly `js`."
  @spec reviewed(String.t() | nil, binary() | nil) :: rule() | nil
  def reviewed(version, js) when is_binary(version) and is_binary(js) do
    sha = StaticPriv.sha256(js)
    Enum.find(@rules, &(&1.version == version and &1.js_sha256 == sha))
  end

  def reviewed(_version, _js), do: nil

  @doc """
  `reviewed/2` of the `lib/kino/js.ex` in the Hex `tarball` (its outer tar,
  already verified against the lock by the caller), read under
  `StaticPriv.contents/1`'s bounds.
  """
  @spec reviewed_tarball(String.t() | nil, binary() | nil) :: rule() | nil
  def reviewed_tarball(version, tarball) when is_binary(tarball) do
    with {:ok, tar} <- StaticPriv.contents(tarball),
         {:ok, [{_name, js}]} <-
           :erl_tar.extract({:binary, tar}, [:memory, {:files, [~c"lib/kino/js.ex"]}]) do
      reviewed(version, js)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def reviewed_tarball(_version, _tarball), do: nil

  @doc """
  The directory `Kino.JS` packs `module`'s assets in: the module's name
  without `Elixir.`, every `.` replaced by `_` (`Kino.VegaLite` gives
  `Kino_VegaLite`). nil for an Erlang module.
  """
  @spec dir_name(atom() | String.t() | nil) :: String.t() | nil
  def dir_name(module) when is_atom(module) and not is_nil(module),
    do: dir_name(Atom.to_string(module))

  def dir_name("Elixir." <> name) when name != "", do: String.replace(name, ".", "_")
  def dir_name(_module), do: nil

  @doc "The directory and hash of an archive path, `:error` for any other path."
  @spec parse_path(term()) :: {:ok, String.t(), String.t()} | :error
  def parse_path(path) when is_binary(path) do
    case Regex.run(@path, path) do
      [_, dir, hash] -> {:ok, dir, hash}
      _ -> :error
    end
  end

  def parse_path(_path), do: :error

  @spec archive_path(String.t(), String.t()) :: String.t()
  def archive_path(dir, hash), do: "priv/assets/#{dir}/#{hash}.tar.gz"

  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @spec max_inflated() :: pos_integer()
  def max_inflated, do: @max_inflated

  @spec mode() :: pos_integer()
  def mode, do: @mode

  @doc "What a manifest lists of an entry: `app`, `path`, `sha256`, `size`, `mode`."
  @spec manifest_entry(map()) :: map()
  def manifest_entry(entry), do: Map.take(entry, @manifest_keys)

  @doc """
  `:ok` when `entries` is no list of foreign files (`nil` or `[]`, with no
  rule) or a well-formed one under a known `rule_id`: at most 64 entries,
  10 MiB in all, each for kino, at a valid path, mode 33188, one per
  directory, the directory `dir_name/1` of its module, whose beam `beams`
  (`"ebin/<Module>.beam"` paths) holds. Nothing is read.
  """
  @spec check_entries(term(), term(), MapSet.t(String.t())) :: :ok | {:error, String.t()}
  def check_entries(none, nil, _beams) when none in [nil, []], do: :ok
  def check_entries([], _rule_id, _beams), do: {:error, "a foreign priv rule without entries"}

  def check_entries(entries, rule_id, beams) when is_list(entries) do
    cond do
      rule(rule_id) == nil -> {:error, "unknown foreign priv rule: #{inspect(rule_id)}"}
      length(entries) > @max_entries -> {:error, "more than #{@max_entries} foreign priv files"}
      true -> entries_ok(entries, beams)
    end
  end

  def check_entries(_entries, _rule_id, _beams), do: {:error, "foreign_priv is not a list"}

  defp entries_ok(entries, beams) do
    with :ok <- each_ok(entries, &entry_ok(&1, beams)),
         :ok <- total_ok(entries) do
      one_per_dir(entries)
    end
  end

  defp each_ok(entries, fun) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case fun.(entry) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp entry_ok(%{"app" => app} = entry, _beams) when app != @target,
    do: {:error, "foreign priv entry for another app: #{inspect(entry["app"])}"}

  defp entry_ok(%{} = entry, beams) do
    with {:ok, dir, _hash} <- path_ok(entry["path"]),
         :ok <- fields_ok(entry),
         :ok <- module_ok(dir, entry["module"]) do
      beam_ok(entry["module"], beams)
    end
  end

  defp entry_ok(_entry, _beams), do: {:error, "malformed foreign priv entry"}

  defp path_ok(path) do
    case parse_path(path) do
      {:ok, dir, hash} -> {:ok, dir, hash}
      :error -> {:error, "malformed foreign priv path: #{inspect(path, printable_limit: 200)}"}
    end
  end

  defp fields_ok(%{"sha256" => sha, "size" => size, "mode" => @mode, "assets_path" => assets})
       when is_binary(sha) and is_integer(size) and size >= 0 and is_binary(assets) and
              assets != "" do
    if Regex.match?(@sha256, sha), do: :ok, else: {:error, "malformed foreign priv entry"}
  end

  defp fields_ok(_entry), do: {:error, "malformed foreign priv entry"}

  defp module_ok(dir, module) when is_binary(module) do
    if dir_name(module) == dir,
      do: :ok,
      else: {:error, "priv/assets/#{dir} is not the directory of #{module}"}
  end

  defp module_ok(_dir, _module), do: {:error, "malformed foreign priv entry"}

  defp beam_ok(module, beams) do
    if MapSet.member?(beams, "ebin/#{module}.beam"),
      do: :ok,
      else: {:error, "#{module} has no beam in the build"}
  end

  defp total_ok(entries) do
    if entries |> Enum.map(& &1["size"]) |> Enum.sum() > @max_bytes,
      do: {:error, "more than 10 MiB of foreign priv files"},
      else: :ok
  end

  defp one_per_dir(entries) do
    entries
    |> Enum.map(fn entry -> entry["path"] |> parse_path() |> elem(1) end)
    |> Enum.frequencies()
    |> Enum.find(fn {_dir, n} -> n > 1 end)
    |> case do
      nil -> :ok
      {dir, _n} -> {:error, "two entries for priv/assets/#{dir}"}
    end
  end
end
