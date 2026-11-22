defmodule Compatibility.CompileInputs do
  @moduledoc """
  A build's `compile_inputs` (compile-time inputs spec): the environment
  variables and config a compile read that a client must check on its own
  side, shared by the worker that writes them and the portal that stores
  and publishes them.

  Each item is exactly one of:

    * `%{"kind" => "env", "name", "value", "set_by" => "host"}`: the value
      came from the builder's environment; a client compares its own.
    * `%{"kind" => "env", "name", "value", "set_by" => "build", "inputs" =>
      "recorded" | "unknown"}`: an earlier write in the same build set it.
      With its writer's inputs recorded a client does not compare it;
      `"unknown"` is a miss.
    * `%{"kind" => "env_all"}`: the compile read the whole environment.
    * `%{"kind" => "config_unrecorded"}`: compile-time config reads were
      not all recorded.
    * `%{"kind" => "config_order", "app", "path" => [key], "reader",
      "default", "seen"}`: an unset key `reader` read outside its tree;
      `default` is `app`'s `.app` env default at the locked version, `seen`
      what the read returned. A client predicts its own compile order and
      compares.
    * `%{"kind" => "platform_define", "regex", "matched"}`: a rebar3
      `platform_define` in the closure whose regex the OTP major alone does
      not decide. `regex` is the regex string rebar3 hands `re:run/3`
      (escapes resolved), `matched` (a boolean) whether it matched the
      builder's `rebar_utils:get_arch/0` string. A client computes its own
      arch string the same way and compares.
    * `%{"kind" => "endian", "value" => "little" | "big"}`: the closure read
      the byte order at compile time (`System.endianness/0`,
      `:erlang.system_info(:endian)`); `value` is the builder's. A client
      compares its own `System.endianness/0`. Judge revision 13 and later.
    * `%{"kind" => "os_type", "family" => "unix" | "win32", "name"}`: the
      closure read the OS type at compile time (`:os.type/0`); `family` and
      `name` are the builder's. A client compares its own `:os.type/0`, both
      elements. Without `name`, every read was one whose caller uses the
      family alone (Elixir's `File.rm_rf/1`), and a client compares the
      family. Judge revision 17 and later.
    * `%{"kind" => "env", "name", "value" => segments, "set_by" =>
      "nerves"}`: a firmware build's read of a variable whose value holds
      where the Nerves toolchain or system lives on the builder
      (`CROSSCOMPILE`): `segments` is the value cut at every
      `NERVES_TOOLCHAIN` and `NERVES_SYSTEM` path (`split/2`), each cut a
      `%{"root" => name}` and the rest literal strings. A client cuts its
      own value of the variable at its own two paths the same way and
      compares the lists: equal means the values differ only in where the
      Nerves artifacts sit, which the firmware build-root rule keeps out of
      the published beams. Judge revision 19 and later.
    * `%{"kind" => "mix_target", "value"}`: a firmware build's compile read
      `Mix.target/0`; `value` is the target it was built for. A client
      compares its own. Judge revision 19 and later.
    * `%{"kind" => "config_all", "app", "entries" => [%{"key", "value"}]}`:
      the closure read `app`'s whole env at compile time
      (`application:get_all_env/1`); `entries` are every key the project's
      config sets for `app`, sorted by key and each once, each value a
      recorded value, at most 128 of them. An empty list is an app the
      config leaves alone. A client compares its own config for `app`,
      the whole map: the same keys with the same values, nothing more.
    * `%{"kind" => "probe", "of" => "module", "name", "answer" => "absent",
      "definers" => [name]}`: the closure asked at compile time whether the
      module `name` (as its atom renders, `Elixir.Poison`, `cowboy_websocket`)
      is there, and nothing in the build defines it. `definers` are the Hex
      package and application names known to define it (the declared ones
      the worker found, and every one the portal's module index shows), sorted
      and each once, at most 64. A client misses when its project can supply
      the module: a dependency named in `definers`, a dependency outside the
      build's closure whose sources define it, or the module on its code path.
    * `%{"kind" => "probe", "of" => "app", "name", "answer" => "absent"}`: the
      same for an application that is no package of the build. A client
      misses when a dependency of its project is that application, or the
      application is on its code path.
    * `%{"kind" => "probe", "of" => "otp_app", "name", "answer" => "absent"}`:
      the same for an installed OTP or Elixir application that no closure
      application lists, so the builder's pruned path never held it. A client
      misses when the application is installed on its side.

  An env item's `value` is a recorded value (`Compatibility.RecordedValue`: base64url ETF
  of `:error` or `{:ok, binary}`) or `"unrecordable"`, which matches nothing.
  """

  alias Compatibility.RecordedValue

  @unrecordable "unrecordable"
  # 128 `env`, 96 `config_order`, 32 of every other kind and 64 `probe`
  # items, as the worker caps them.
  @max_items 320
  @max_name_bytes 256
  @max_regex_bytes 1024
  @os_families ["unix", "win32"]
  # An `:os.type/0` name as it renders: `linux`, `darwin`, `freebsd`, `nt`.
  @os_name ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @nerves_roots ["NERVES_TOOLCHAIN", "NERVES_SYSTEM"]
  @max_segment_bytes 4096
  @max_segments 64
  # The share of `@max_items` the worker gives `config_order` items, next to
  # 128 `env` items and 32 of every other kind.
  @max_config_order_items 96
  @max_config_all_entries 128
  @max_probe_items 64
  @probe_kinds ["module", "app", "otp_app"]
  # A module as its atom renders (`Elixir.Jason.Encoder`, `cowboy_websocket`)
  # and an application name.
  @module_name ~r/\A[A-Za-z_][A-Za-z0-9_.@]{0,254}\z/
  @app_name ~r/\A[a-z][a-z0-9_]{0,254}\z/

  @doc "The value of an item whose value was not recorded: it matches nothing."
  @spec unrecordable() :: String.t()
  def unrecordable, do: @unrecordable

  @doc """
  How many `config_order` items a build records at most: more record
  `config_unrecorded` instead, so the list stays within the shared cap.
  """
  @spec max_config_order_items() :: pos_integer()
  def max_config_order_items, do: @max_config_order_items

  @doc "The list when every item has exactly one of the shapes above, `:error` otherwise."
  @spec validate(term()) :: {:ok, [map()] | nil} | :error
  def validate(nil), do: {:ok, nil}

  def validate(items) when is_list(items) and length(items) <= @max_items do
    if Enum.all?(items, &item?/1), do: {:ok, items}, else: :error
  end

  def validate(_items), do: :error

  @doc "Whether `value` may stand as an item's or a config item's recorded value."
  @spec value?(term()) :: boolean()
  def value?(@unrecordable), do: true
  def value?(value), do: RecordedValue.acceptable?(value)

  @doc """
  Whether a client must check any item: everything but an env variable the
  build set itself from recorded inputs.
  """
  @spec needs_check?([map()] | nil) :: boolean()
  def needs_check?(nil), do: false
  def needs_check?(items) when is_list(items), do: Enum.any?(items, &check?/1)

  defp check?(%{"kind" => "env", "set_by" => "build", "inputs" => "recorded"}), do: false
  defp check?(_item), do: true

  defp item?(%{"kind" => kind} = item) when kind in ["env_all", "config_unrecorded"],
    do: map_size(item) == 1

  defp item?(%{"kind" => "env", "name" => name, "value" => value, "set_by" => "host"} = item),
    do: map_size(item) == 4 and name?(name) and value?(value)

  defp item?(
         %{
           "kind" => "env",
           "name" => name,
           "value" => value,
           "set_by" => "build",
           "inputs" => inputs
         } =
           item
       )
       when inputs in ["recorded", "unknown"],
       do: map_size(item) == 5 and name?(name) and value?(value)

  defp item?(
         %{
           "kind" => "config_order",
           "app" => app,
           "path" => [key],
           "reader" => reader,
           "default" => default,
           "seen" => seen
         } = item
       ),
       do:
         map_size(item) == 6 and name?(app) and name?(key) and name?(reader) and value?(default) and
           value?(seen)

  defp item?(%{"kind" => "endian", "value" => value} = item) when value in ["little", "big"],
    do: map_size(item) == 2

  defp item?(%{"kind" => "os_type", "family" => family, "name" => name} = item)
       when family in @os_families,
       do: map_size(item) == 3 and os_name?(name)

  defp item?(%{"kind" => "os_type", "family" => family} = item) when family in @os_families,
    do: map_size(item) == 2

  defp item?(%{"kind" => "env", "name" => name, "value" => value, "set_by" => "nerves"} = item),
    do: map_size(item) == 4 and name?(name) and segments?(value)

  defp item?(%{"kind" => "mix_target", "value" => value} = item),
    do: map_size(item) == 2 and name?(value)

  defp item?(%{"kind" => "platform_define", "regex" => regex, "matched" => matched} = item)
       when is_boolean(matched),
       do: map_size(item) == 3 and regex?(regex)

  defp item?(%{"kind" => "config_all", "app" => app, "entries" => entries} = item),
    do: map_size(item) == 3 and name?(app) and entries?(entries)

  defp item?(
         %{
           "kind" => "probe",
           "of" => "module",
           "name" => name,
           "answer" => "absent",
           "definers" => definers
         } = item
       ),
       do: map_size(item) == 5 and module_name?(name) and definers?(definers)

  defp item?(%{"kind" => "probe", "of" => of, "name" => name, "answer" => "absent"} = item)
       when of in ["app", "otp_app"],
       do: map_size(item) == 4 and app_name?(name)

  defp item?(_item), do: false

  # A `config_all` item's entries: a list of `%{"key", "value"}`, each key a
  # name, each value a recorded one, strictly sorted by key (so each once).
  defp entries?(entries) when is_list(entries) and length(entries) <= @max_config_all_entries do
    keys = for %{"key" => key} <- entries, do: key

    Enum.all?(entries, &entry?/1) and length(keys) == length(entries) and
      keys == Enum.sort(Enum.uniq(keys))
  end

  defp entries?(_entries), do: false

  defp entry?(%{"key" => key, "value" => value} = entry),
    do: map_size(entry) == 2 and name?(key) and value?(value)

  defp entry?(_entry), do: false

  # A probe item's definers: package or application names, strictly sorted
  # (so each once), at most `@max_probe_items`.
  defp definers?(definers) when is_list(definers) and length(definers) <= @max_probe_items,
    do: Enum.all?(definers, &app_name?/1) and definers == Enum.sort(Enum.uniq(definers))

  defp definers?(_definers), do: false

  @doc "The most `probe` items a build records; more record `config_unrecorded`."
  @spec max_probe_items() :: pos_integer()
  def max_probe_items, do: @max_probe_items

  @doc "What a `probe` item may ask about (`of`)."
  @spec probe_kinds() :: [String.t()]
  def probe_kinds, do: @probe_kinds

  @doc "Whether `name` may stand as a module `probe` item's name."
  @spec module_name?(term()) :: boolean()
  def module_name?(name) when is_binary(name), do: Regex.match?(@module_name, name)
  def module_name?(_name), do: false

  @doc "Whether `name` may stand as an application `probe` item's name, or a definer."
  @spec app_name?(term()) :: boolean()
  def app_name?(name) when is_binary(name), do: Regex.match?(@app_name, name)
  def app_name?(_name), do: false

  @doc "The most entries a `config_all` item may carry."
  @spec max_config_all_entries() :: pos_integer()
  def max_config_all_entries, do: @max_config_all_entries

  @doc "The `:os.type/0` families an `os_type` item may carry."
  @spec os_families() :: [String.t()]
  def os_families, do: @os_families

  @doc "Whether `name` may stand as an `os_type` item's name (`:os.type/0`'s second element)."
  @spec os_name?(term()) :: boolean()
  def os_name?(name) when is_binary(name), do: Regex.match?(@os_name, name)
  def os_name?(_name), do: false

  @doc "Whether `regex` may stand as a `platform_define` item's regex."
  @spec regex?(term()) :: boolean()
  def regex?(regex) when is_binary(regex) do
    byte_size(regex) in 1..@max_regex_bytes and String.valid?(regex) and
      not String.contains?(regex, <<0>>)
  end

  def regex?(_regex), do: false

  @doc "The names whose paths a `set_by: \"nerves\"` item's value is cut at."
  @spec nerves_roots() :: [String.t()]
  def nerves_roots, do: @nerves_roots

  @doc """
  `value` cut at every occurrence of a root's path, leftmost first and, of
  two that start at the same byte, the longer: each cut is
  `%{"root" => name}`, the text between cuts a literal string, and no
  literal is empty. `roots` is `[{name, path}]`; an empty path cuts
  nothing. The worker and every client cut the same way, so two values
  that differ only in the roots' paths cut to the same list.
  """
  @spec split(String.t(), [{String.t(), String.t()}]) :: [String.t() | map()]
  def split(value, roots) when is_binary(value) do
    roots =
      roots
      |> Enum.filter(fn {_name, path} -> is_binary(path) and path != "" end)
      |> Enum.sort_by(fn {_name, path} -> -byte_size(path) end)

    do_split(value, roots, "", [])
  end

  defp do_split(<<>>, _roots, literal, acc), do: Enum.reverse(push_literal(acc, literal))

  defp do_split(<<byte, rest::binary>> = value, roots, literal, acc) do
    case Enum.find(roots, fn {_name, path} -> String.starts_with?(value, path) end) do
      {name, path} ->
        rest = binary_part(value, byte_size(path), byte_size(value) - byte_size(path))
        do_split(rest, roots, "", [%{"root" => name} | push_literal(acc, literal)])

      nil ->
        do_split(rest, roots, literal <> <<byte>>, acc)
    end
  end

  defp push_literal(acc, ""), do: acc
  defp push_literal(acc, literal), do: [literal | acc]

  # One canonical split (`split/2`): at least one root, every literal a
  # non-empty, NUL-free UTF-8 string, no two literals next to each other.
  defp segments?(segments) when is_list(segments) and length(segments) in 1..@max_segments do
    Enum.all?(segments, &segment?/1) and Enum.any?(segments, &is_map/1) and
      not Enum.any?(Enum.chunk_every(segments, 2, 1, :discard), fn [a, b] ->
        is_binary(a) and is_binary(b)
      end)
  end

  defp segments?(_segments), do: false

  defp segment?(%{"root" => root} = segment), do: map_size(segment) == 1 and root in @nerves_roots

  defp segment?(literal) when is_binary(literal) do
    byte_size(literal) in 1..@max_segment_bytes and String.valid?(literal) and
      not String.contains?(literal, <<0>>)
  end

  defp segment?(_segment), do: false

  @doc "Whether `name` may stand as an `env` item's name."
  @spec name?(term()) :: boolean()
  def name?(name) when is_binary(name) do
    byte_size(name) in 1..@max_name_bytes and String.valid?(name) and
      not String.contains?(name, ["=", <<0>>])
  end

  def name?(_name), do: false
end
