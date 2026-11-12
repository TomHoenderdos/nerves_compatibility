defmodule Portal.Catalog.SkipReasons do
  @moduledoc """
  Sorts the `reason` of a `skipped` toolchain build (`Portal.Catalog.ToolchainBuild`)
  into a root cause, for the admin Not precompiled tab
  (`Portal.Catalog.NotPrecompiled`).

  The reasons are the worker's, and this follows their real shapes rather
  than guessing from samples:

    * the static rules of `NccWorker.BuildSelection`: "no compiled beams",
      "nerves-specific source", "reads the target or ships native code",
      "calls <mfa>" and "calls a NIF or port driver";
    * the trace refusals of `NccWorker.Portability`, whose prefixes are
      `Compatibility.Portability.refusal_prefixes/0`. A host read is
      `"compile-time host read: <mfa>[ (<key or variable>)]..."`
      (`NccWorker.Portability.Events`), and one in a dependency's `mix.exs`
      is `"compile-time host read in mix.exs: <mfa> <why> (<path>:<line>)"`;
    * the rebar3 rules (`NccWorker.Portability.Rebar`): "rebar3 build runs
      <pre_hooks | post_hooks | provider_hooks | plugins>", "rebar3 build
      evaluates rebar.config.script", "rebar3 build uses platform_define";
    * R3 taint, `"closure dependency observed the host: <app> (<its own
      reason>)"`, whose inner reason is classified the same way and whose
      `<app>` is the `blocker`;
    * `Compatibility.Portability.could_not_judge/0`, with the
      `" (transient N times)"` suffix `Portal.Catalog.Ingestion` adds at the
      transient cap.

  Anything else is `:other`. Pure: no database, no state.
  """

  @type class ::
          :env_read
          | :host_read
          | :elixir_version
          | :native_code
          | :build_hooks
          | :nerves_specific
          | :no_beams
          | :could_not_judge
          | :other

  @type t :: %{class: class(), detail: String.t() | nil, blocker: String.t() | nil}

  @classes [
    :env_read,
    :host_read,
    :elixir_version,
    :native_code,
    :build_hooks,
    :nerves_specific,
    :no_beams,
    :could_not_judge,
    :other
  ]

  @labels %{
    env_read: "Env var read at compile time",
    host_read: "Other host read at compile time",
    elixir_version: "Elixir patch version dependence",
    native_code: "Native code",
    build_hooks: "rebar3 build hooks",
    nerves_specific: "Nerves-specific source",
    no_beams: "No compiled beams",
    could_not_judge: "Could not be judged",
    other: "Other"
  }

  @closure "closure dependency observed the host: "
  @host_read "compile-time host read: "
  @host_read_mix_exs "compile-time host read in mix.exs: "
  @elixir_patch "compile-time Elixir patch dependence: "
  @natively_built "calls natively built dependency at compile time: "
  @native_lib "compile-time native library load: "

  # The mfas whose call is a read of the environment (`Events` puts the
  # variable's name after the mfa when the trace saw it).
  @env_mfas ~w(os:getenv/0 os:getenv/1 os:getenv/2 os:list_env_vars/0 os:env/0)

  # A rule-1 "calls <mfa>" that is a NIF or a port, not a shell or an
  # executable lookup.
  @native_calls ~w(erlang:load_nif/2 erlang:open_port/2 erl_ddll:load/2 erl_ddll:load_driver/2)

  @doc "Every class, in display order."
  @spec classes() :: [class()]
  def classes, do: @classes

  @doc "A human label for `class`."
  @spec label(class()) :: String.t()
  def label(class), do: Map.fetch!(@labels, class)

  @doc """
  The root cause of `reason`: its `class`, a `detail` within the class (the
  environment variable, the host call, the hook) when the reason names one,
  and the `blocker`, the closure dependency whose own compile observed the
  host, when the reason is R3 taint.
  """
  @spec classify(String.t() | nil) :: t()
  def classify(@closure <> rest) do
    {blocker, inner} = split_closure(rest)
    {class, detail} = own(inner)
    %{class: class, detail: detail, blocker: blocker}
  end

  def classify(reason) when is_binary(reason) do
    {class, detail} = own(reason)
    %{class: class, detail: detail, blocker: nil}
  end

  def classify(_reason), do: %{class: :other, detail: nil, blocker: nil}

  # "<app> (<reason>)": the app has no spaces, the reason is everything in
  # the outer parentheses.
  defp split_closure(rest) do
    case String.split(rest, " (", parts: 2) do
      [app, inner] -> {app, String.replace_suffix(inner, ")", "")}
      [app] -> {String.trim(app), ""}
    end
  end

  defp own("portability could not be judged" <> _), do: {:could_not_judge, nil}
  defp own("beam scan incomplete"), do: {:could_not_judge, nil}
  defp own("no compiled beams"), do: {:no_beams, nil}
  defp own("nerves-specific source"), do: {:nerves_specific, nil}
  defp own("reads the target or ships native code"), do: {:native_code, nil}
  defp own("calls a NIF or port driver"), do: {:native_code, nil}
  defp own(@natively_built <> mfa), do: {:native_code, first_token(mfa)}
  defp own(@native_lib <> _path), do: {:native_code, "native library load"}
  defp own("rebar3 build runs " <> key), do: {:build_hooks, key}

  defp own("rebar3 build evaluates rebar.config.script"),
    do: {:build_hooks, "rebar.config.script"}

  defp own("rebar3 build uses platform_define"), do: {:build_hooks, "platform_define"}
  defp own(@elixir_patch <> rest), do: {:elixir_version, first_token(rest)}
  defp own(@host_read_mix_exs <> rest), do: host_read(rest)
  defp own(@host_read <> rest), do: host_read(rest)

  defp own("calls " <> mfa) do
    if mfa in @native_calls, do: {:native_code, mfa}, else: {:other, mfa}
  end

  defp own(_reason), do: {:other, nil}

  # "<mfa>[ (<name>)]...": the name is a single word in parentheses right
  # after the mfa; a stack note ("(dispatcher stack, ...)") has spaces.
  defp host_read(rest) do
    {mfa, name} =
      case Regex.run(~r/\A(\S+)(?: \(([^\s()]+)\))?/, rest) do
        [_, mfa, name] -> {mfa, name}
        [_, mfa] -> {mfa, nil}
        nil -> {nil, nil}
      end

    cond do
      mfa in @env_mfas -> {:env_read, name}
      is_nil(mfa) -> {:host_read, nil}
      is_nil(name) -> {:host_read, mfa}
      true -> {:host_read, "#{mfa} (#{name})"}
    end
  end

  defp first_token(text) do
    case String.split(text, " ", parts: 2) do
      [""] -> nil
      [token | _] -> token
    end
  end
end
