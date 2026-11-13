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
  that way in public manifests. Reading the whole environment, more than
  128 variables, or a name no variable can have (empty, with `=` or NUL,
  over 256 bytes, not a string: `Compatibility.CompileInputs.name?/1`) is
  `env_all`.

  Each kind has its own cap, and the caps together fit the shared 256-item
  cap of `Compatibility.CompileInputs`: 128 `env` items, 96 `config_order`
  items (`Compatibility.CompileInputs.max_config_order_items/0`) and 32 of
  every other kind. A `config_order` input the shared shape rejects (a
  name no item may carry) records `config_unrecorded` instead. A kind over its cap records that it
  was not recorded instead (`env_all` for `env`, `config_unrecorded` for
  the rest), so the list never grows past the shared cap and the build is
  never dropped for it.
  """

  alias Compatibility.{CompileInputs, RecordedValue}

  @max_env_items 128
  @max_other_items 32
  @env_all %{"kind" => "env_all"}
  @unrecorded %{"kind" => "config_unrecorded"}
  @private ~r/\ANCC_|TOKEN|SECRET|PASSW|API_KEY|PRIVATE|CREDENTIAL|_PASS\z|_PWD\z|_KEY(\z|_)|(\A|_)AUTH\z|_PROXY\z/i
  # A URL carrying userinfo (`scheme://user:pass@host`, `scheme://token@`),
  # anywhere in the decoded value.
  @userinfo_url ~r{[a-z][a-z0-9+.-]*://[^/?#@\s]*@}i

  @spec build([{term(), term()}], [map()]) :: [map()]
  def build(decided, config_inputs) do
    reads = for {_owner, {:observe, "env_reads", item}} <- decided, do: item

    writes =
      for {owner, {:observe, "env_writes", item}} <- decided, is_binary(owner), do: item

    {all, named} = Enum.split_with(reads, &(&1["all"] == true))
    writer_files = MapSet.new(writes, &file_key/1)

    {named_ok, named_bad} =
      named
      |> Enum.filter(&(&1["slice_allowed"] != true or MapSet.member?(writer_files, file_key(&1))))
      |> Enum.split_with(&CompileInputs.name?(&1["name"]))

    env =
      named_ok
      |> Enum.map(&item(&1, writes, named))
      |> Enum.uniq()
      |> Enum.sort_by(&{&1["name"], &1["set_by"], &1["value"], &1["inputs"]})

    {env, all?} =
      if length(env) > @max_env_items,
        do: {[], true},
        else: {env, all != [] or named_bad != []}

    env ++ cap_config(if(all?, do: [@env_all], else: []) ++ config_inputs)
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

  # A config_order input the shared shape rejects (a name no item may carry)
  # would make the portal reject the whole list: it is not recorded instead.
  defp carriable(%{"kind" => "config_order"} = input) do
    case CompileInputs.validate([input]) do
      {:ok, _} -> input
      :error -> @unrecorded
    end
  end

  defp carriable(input), do: input

  defp item(read, writes, reads) do
    base = %{"kind" => "env", "name" => read["name"], "value" => value_of(read)}

    case writer(read, writes) do
      nil -> Map.put(base, "set_by", "host")
      write -> Map.merge(base, %{"set_by" => "build", "inputs" => inputs_of(write, reads)})
    end
  end

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

  # Only a value the trace recorded can match: two missing or unrecordable
  # captures say nothing about each other.
  defp same_value(%{"value" => returned} = write, returned) when is_binary(returned) do
    if RecordedValue.acceptable?(returned), do: write
  end

  defp same_value(_write, _returned), do: nil

  defp inputs_of(%{"file" => file} = write, reads) when is_binary(file) do
    earlier = Enum.filter(reads, &(file_key(&1) == file_key(write) and before?(&1, write)))

    if Enum.all?(earlier, &recorded?/1),
      do: "recorded",
      else: "unknown"
  end

  defp inputs_of(_write, _reads), do: "unknown"

  defp recorded?(read),
    do: CompileInputs.name?(read["name"]) and value_of(read) != CompileInputs.unrecordable()

  defp before?(%{"ts" => a}, %{"ts" => b}) when is_integer(a) and is_integer(b), do: a < b
  defp before?(_a, _b), do: false

  defp file_key(item), do: {item["vm"], item["file"]}
end
