defmodule NccWorker.Portability.CompileInputs do
  @moduledoc """
  The build's `compile_inputs` (compile-time inputs spec, section 2): every
  environment variable the package's closure read at compile time, and what
  it read, instead of a refusal. Shape: `Compatibility.CompileInputs`.

  A read (`os:getenv/1`, its value from the tracer's return capture) is
  `set_by: "build"` when an earlier write in the same build (`os:putenv/2`,
  `os:unsetenv/1`) set the value it returned: in the Mix VM, the latest
  write of that name before it, when its value is the one returned; in a
  child VM, whose clock is its own, a Mix-VM write of that value. Such a
  value follows from the build's own inputs, so a client does not compare
  it, as long as the writer's inputs were recorded: `inputs: "recorded"`
  when the write has a source file and every env read from that file before
  it is itself recorded, `"unknown"` otherwise. Any other read is
  `set_by: "host"`. Only a write made in the package's closure (its owner
  the package or a closure dependency) is the build's: one in the
  project's own `mix.exs` or outside every window is something a client's
  project does not do. A child-VM read is matched by value to a Mix-VM
  write made at any time, by design: the clocks do not compare, and a
  write of the same value elsewhere in the build is rare.

  A read in a dependency's `mix.exs` that R4 found cannot reach a
  compile-relevant key (`slice_allowed`) is no input, unless its file also
  writes the environment: then it may decide what the write sets.

  A value the trace did not capture, could not record, read under a
  private-looking name (`NCC_*`; a name with TOKEN, SECRET, PASSW, API_KEY,
  PRIVATE or CREDENTIAL; one ending in `_PASS`, `_PWD`, `_KEY`, `_AUTH` or
  `_PROXY`, or `AUTH` itself; in any case), or that holds a URL with
  userinfo (`scheme://user:pass@`) is `"unrecordable"`, which matches
  nothing: the builder's environment holds no secret, and this keeps it
  that way in public manifests. A variable that was unset (`:error`) is
  recorded as unset whatever its name: that reveals nothing, and a client
  without it matches (yamerl's `rebar.config.script` always reads
  `GITHUB_TOKEN`). Reading the whole environment, more than
  128 variables, or a name no variable can have (empty, with `=` or NUL,
  over 256 bytes, not a string: `Compatibility.CompileInputs.name?/1`) is
  `env_all`.

  Each kind has its own cap, and the caps together fit the shared 256-item
  cap of `Compatibility.CompileInputs`: 128 `env` items, 96 `config_order`
  items (`Compatibility.CompileInputs.max_config_order_items/0`) and 32 of
  every other kind (`platform_define` items among them, rebar3's
  `platform_define` regexes the OTP major does not decide, `Rebar`). A `config_order` input the shared shape rejects (a
  name no item may carry) records `config_unrecorded` instead. A kind over its cap records that it
  was not recorded instead (`env_all` for `env`, `config_unrecorded` for
  the rest), so the list never grows past the shared cap and the build is
  never dropped for it.

  A compile-time read of the byte order (`endian_reads`, `Events`) is one
  `endian` item, valued with the byte order `build/5` is given (the traced
  compile's, from the tracer's start line); without a known one it is
  `config_unrecorded`.

  A compile-time read of the OS type (`os_type_reads`, `Events`) is one
  `os_type` item, valued with the `[family, name]` `build/5` is given (the
  traced compile's, from the tracer's start line). It carries `name` unless
  every read is one whose caller keeps only the family (`"scope"`
  `"family"`, Elixir's `File.rm_rf/1`, or `"covered"`, OTP's `os:type/0`
  reading `system_info(os_type)` for a caller its own read names) and at
  least one is `"family"`. Without a known OS type it is
  `config_unrecorded`.

  A firmware build's trace (`NccWorker.Portability.target_inputs/3`) adds
  three things, through `build/5`'s options:

    * `roots:` (`[{name, path}]`, the builder's `NERVES_TOOLCHAIN` and
      `NERVES_SYSTEM`): a host read whose recorded value holds one of those
      paths is `set_by: "nerves"`, its value cut at them
      (`Compatibility.CompileInputs.split/2`), so a client compares it with
      its own value cut at its own paths. A value that does not cut into
      the shared shape stays as read.
    * `target:`: any read of `Mix.target/0` (`target_reads`) is one
      `mix_target` item with that target; without a valid one it is
      `config_unrecorded`.
    * `native_build` observations, the reviewed native build tool's own
      activity, which records no input: a write made after one in the same
      window and VM has inputs `"unknown"`, since that activity may have
      decided its value.

  A write with no source file (a package fun Mix runs as an alias that
  tail-called `System.put_env/2`, so no frame of it is left) has inputs
  `"recorded"` only when every env read made before it in its VM, by any
  owner, is recorded.
  """

  alias Compatibility.{CompileInputs, RecordedValue}

  @max_env_items 128
  @max_other_items 32
  @env_all %{"kind" => "env_all"}
  @unrecorded %{"kind" => "config_unrecorded"}
  @private ~r/\ANCC_|TOKEN|SECRET|PASSW|API_KEY|PRIVATE|CREDENTIAL|_PASS\z|_PWD\z|_KEY(\z|_)|(\A|_)AUTH\z|_PROXY\z/i
  # `:error`, as the tracer captures an unset variable's `os:getenv/1`.
  @unset :error |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)
  # A URL carrying userinfo (`scheme://user:pass@host`, `scheme://token@`),
  # anywhere in the decoded value.
  @userinfo_url ~r{[a-z][a-z0-9+.-]*://[^/?#@\s]*@}i

  @spec build([{term(), term()}], [map()], term(), term(), keyword()) :: [map()]
  def build(decided, config_inputs, endian \\ nil, os_type \\ nil, opts \\ []) do
    reads = for {_owner, {:observe, "env_reads", item}} <- decided, do: item

    writes =
      for {owner, {:observe, "env_writes", item}} <- decided,
          is_binary(owner),
          do: Map.put(item, "owner", owner)

    native = for {owner, {:observe, "native_build", item}} <- decided, do: {owner, item}
    roots = roots(Keyword.get(opts, :roots, []))

    {all, named} = Enum.split_with(reads, &(&1["all"] == true))
    writer_files = MapSet.new(writes, &file_key/1)

    {named_ok, named_bad} =
      named
      |> Enum.filter(&(&1["slice_allowed"] != true or MapSet.member?(writer_files, file_key(&1))))
      |> Enum.split_with(&CompileInputs.name?(&1["name"]))

    env =
      named_ok
      |> Enum.map(&item(&1, writes, named, native, roots))
      |> Enum.uniq()
      |> Enum.sort_by(&{&1["name"], &1["set_by"], &1["value"], &1["inputs"]})

    {env, all?} =
      if length(env) > @max_env_items,
        do: {[], true},
        else: {env, all != [] or named_bad != []}

    env ++
      cap_config(
        if(all?, do: [@env_all], else: []) ++
          endian_inputs(decided, endian) ++
          os_type_inputs(decided, os_type) ++
          target_inputs(decided, Keyword.get(opts, :target)) ++ config_inputs
      )
  end

  # The firmware build's target, for its `Mix.target/0` reads: an item a
  # client compares, never nothing.
  defp target_inputs(decided, target) do
    cond do
      not Enum.any?(decided, &match?({_owner, {:observe, "target_reads", _}}, &1)) -> []
      CompileInputs.name?(target) -> [%{"kind" => "mix_target", "value" => target}]
      true -> [@unrecorded]
    end
  end

  # Only the two Nerves paths, and only a path that is one.
  defp roots(roots) when is_list(roots) do
    for {name, path} <- roots,
        name in CompileInputs.nerves_roots(),
        is_binary(path) and path != "",
        do: {name, path}
  end

  defp roots(_roots), do: []

  # Any byte-order read in the closure (`Events`, `endian_reads`) is one
  # `endian` item with the byte order the traced compile ran with (the
  # tracer's start line). A read whose byte order is not known records
  # `config_unrecorded`, which no client matches: never nothing.
  defp endian_inputs(decided, endian) do
    cond do
      not Enum.any?(decided, &match?({_owner, {:observe, "endian_reads", _}}, &1)) -> []
      endian in ["little", "big"] -> [%{"kind" => "endian", "value" => endian}]
      true -> [@unrecorded]
    end
  end

  # Any OS-type read in the closure is one `os_type` item with the OS type
  # the traced compile ran with. The name is left out only when every read
  # provably reaches the family alone; a read whose scope is missing or
  # unknown reaches the whole tuple. Without a known OS type the item is
  # `config_unrecorded`, which no client matches: never nothing.
  defp os_type_inputs(decided, os_type) do
    case for({_owner, {:observe, "os_type_reads", read}} <- decided, do: read["scope"]) do
      [] -> []
      scopes -> [os_type_item(os_type, scopes)]
    end
  end

  defp os_type_item([family, name], scopes) do
    if family in CompileInputs.os_families() and CompileInputs.os_name?(name),
      do: os_type_item(family, name, scopes),
      else: @unrecorded
  end

  defp os_type_item(_os_type, _scopes), do: @unrecorded

  defp os_type_item(family, name, scopes) do
    if "family" in scopes and Enum.all?(scopes, &(&1 in ["family", "covered"])),
      do: %{"kind" => "os_type", "family" => family},
      else: %{"kind" => "os_type", "family" => family, "name" => name}
  end

  defp cap_config(inputs) do
    inputs = inputs |> Enum.map(&carriable/1) |> Enum.uniq()
    {orders, others} = Enum.split_with(inputs, &(&1["kind"] == "config_order"))

    {orders, others} =
      if length(orders) > CompileInputs.max_config_order_items(),
        do: {[], Enum.uniq(others ++ [@unrecorded])},
        else: {orders, others}

    others =
      if length(others) > @max_other_items,
        do: Enum.uniq(Enum.filter(others, &(&1 == @env_all)) ++ [@unrecorded]),
        else: others

    others ++ orders
  end

  # A config_order, platform_define or config_all input the shared shape
  # rejects (a name no item may carry, an over-long regex) would make the portal
  # reject the whole list: it is not recorded instead.
  defp carriable(%{"kind" => kind} = input)
       when kind in ["config_order", "platform_define", "config_all"] do
    case CompileInputs.validate([input]) do
      {:ok, _} -> input
      :error -> @unrecorded
    end
  end

  defp carriable(input), do: input

  defp item(read, writes, reads, native, roots) do
    base = %{"kind" => "env", "name" => read["name"], "value" => value_of(read)}

    case writer(read, writes) do
      nil ->
        host(base, roots)

      write ->
        Map.merge(base, %{"set_by" => "build", "inputs" => inputs_of(write, reads, native)})
    end
  end

  # A recorded value holding a Nerves path, cut at it; anything else as read.
  defp host(base, []), do: Map.put(base, "set_by", "host")

  defp host(%{"value" => value} = base, roots) do
    with {:ok, {:ok, string}} when is_binary(string) <- decode(value),
         segments = CompileInputs.split(string, roots),
         true <- Enum.any?(segments, &is_map/1),
         item = %{base | "value" => segments} |> Map.put("set_by", "nerves"),
         {:ok, [_]} <- CompileInputs.validate([item]) do
      item
    else
      _ -> Map.put(base, "set_by", "host")
    end
  end

  # An unset variable reveals nothing, whatever its name: its value is
  # recorded so a client without it matches. Only a set value can hold a
  # secret.
  defp value_of(%{"name" => name, "returned" => @unset}) when is_binary(name), do: @unset

  defp value_of(%{"name" => name, "returned" => returned})
       when is_binary(name) and is_binary(returned) do
    if Regex.match?(@private, name) or not RecordedValue.acceptable?(returned) or
         userinfo?(returned),
       do: CompileInputs.unrecordable(),
       else: returned
  end

  defp value_of(_read), do: CompileInputs.unrecordable()

  # Matched on the raw ETF bytes, where a string value sits as it is: no
  # term is decoded.
  defp userinfo?(returned) do
    case Base.url_decode64(returned, padding: false) do
      {:ok, bytes} -> Regex.match?(@userinfo_url, bytes)
      :error -> true
    end
  end

  defp writer(%{"vm" => "main"} = read, writes) do
    writes
    |> Enum.filter(&(&1["vm"] == "main" and &1["name"] == read["name"] and before?(&1, read)))
    |> Enum.max_by(& &1["ts"], fn -> nil end)
    |> same_value(read["returned"])
  end

  defp writer(read, writes) do
    writes
    |> Enum.filter(
      &(&1["vm"] == "main" and &1["name"] == read["name"] and same_value(&1, read["returned"]))
    )
    |> Enum.max_by(& &1["ts"], fn -> nil end)
  end

  # The string a recorded `{:ok, binary}` holds, read from its bytes alone
  # (an ETF small tuple of the atom `ok` and a binary, nothing after): no
  # term is decoded. Any other shape is `:error`, and the value stays as read.
  defp decode(value) do
    with {:ok, bin} <- Base.url_decode64(value, padding: false),
         <<131, 104, 2, rest::binary>> <- bin,
         {:ok, <<109, size::32, string::binary-size(size)>>} <- ok_atom(rest) do
      {:ok, {:ok, string}}
    else
      _ -> :error
    end
  end

  defp ok_atom(<<119, 2, "ok", rest::binary>>), do: {:ok, rest}
  defp ok_atom(<<115, 2, "ok", rest::binary>>), do: {:ok, rest}
  defp ok_atom(<<118, 2::16, "ok", rest::binary>>), do: {:ok, rest}
  defp ok_atom(<<100, 2::16, "ok", rest::binary>>), do: {:ok, rest}
  defp ok_atom(_bin), do: :error

  # Only a value the trace recorded can match: two missing or unrecordable
  # captures say nothing about each other.
  defp same_value(%{"value" => returned} = write, returned) when is_binary(returned) do
    if RecordedValue.acceptable?(returned), do: write
  end

  defp same_value(_write, _returned), do: nil

  defp inputs_of(write, reads, native) do
    earlier =
      if is_binary(write["file"]),
        do: Enum.filter(reads, &(file_key(&1) == file_key(write) and before?(&1, write))),
        else: Enum.filter(reads, &(&1["vm"] == write["vm"] and before?(&1, write)))

    if Enum.all?(earlier, &recorded?/1) and not native_before?(write, native),
      do: "recorded",
      else: "unknown"
  end

  # Native build activity (`native_build`) in the write's own window and VM
  # before it: what it did is no input anyone records.
  defp native_before?(write, native) do
    Enum.any?(native, fn {owner, item} ->
      owner == write["owner"] and item["vm"] == write["vm"] and before?(item, write)
    end)
  end

  defp recorded?(read),
    do: CompileInputs.name?(read["name"]) and value_of(read) != CompileInputs.unrecordable()

  defp before?(%{"ts" => a}, %{"ts" => b}) when is_integer(a) and is_integer(b), do: a < b
  defp before?(_a, _b), do: false

  defp file_key(item), do: {item["vm"], item["file"]}
end
