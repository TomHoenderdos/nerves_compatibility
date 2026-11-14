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

  `value` is a recorded value (`Compatibility.RecordedValue`: base64url ETF
  of `:error` or `{:ok, binary}`) or `"unrecordable"`, which matches nothing.
  """

  alias Compatibility.RecordedValue

  @unrecordable "unrecordable"
  @max_items 256
  @max_name_bytes 256
  @max_regex_bytes 1024
  # The share of `@max_items` the worker gives `config_order` items, next to
  # 128 `env` items and 32 of every other kind.
  @max_config_order_items 96

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

  defp item?(%{"kind" => "platform_define", "regex" => regex, "matched" => matched} = item)
       when is_boolean(matched),
       do: map_size(item) == 3 and regex?(regex)

  defp item?(_item), do: false

  @doc "Whether `regex` may stand as a `platform_define` item's regex."
  @spec regex?(term()) :: boolean()
  def regex?(regex) when is_binary(regex) do
    byte_size(regex) in 1..@max_regex_bytes and String.valid?(regex) and
      not String.contains?(regex, <<0>>)
  end

  def regex?(_regex), do: false

  @doc "Whether `name` may stand as an `env` item's name."
  @spec name?(term()) :: boolean()
  def name?(name) when is_binary(name) do
    byte_size(name) in 1..@max_name_bytes and String.valid?(name) and
      not String.contains?(name, ["=", <<0>>])
  end

  def name?(_name), do: false
end
