defmodule NccWorker.Tracer.ConfigOverlayTraceTest do
  # A config variant's overlay (`Compatibility.ConfigVariants`) on real
  # traced compiles: the trace records the overlay's values in the result's
  # `compile_env`, the project's `config/config.exs` is not judged as a read
  # of the host, the overlay changes only the code that reads it, and no R5
  # item enters a `.app`. Starts real `elixir` VMs: one such module at a time
  # (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias Compatibility.ConfigVariants
  alias NccWorker.AppFile
  alias NccWorker.Portability.ConfigReads
  alias NccWorker.TracerFixtures
  alias NccWorker.Worker

  import NccWorker.TracerFixtures, only: [lib: 3]

  @moduletag timeout: 600_000

  # A dependency named as LiveView, reading its keys the way LiveView does:
  # `root_tag_attribute` and the `~H` engine's debug keys from a macro, so in
  # the caller's compile, and `enable_expensive_runtime_checks` with
  # `compile_env` in its own module body.
  @live_view """
  defmodule Phoenix.LiveView.FxRoot do
    @checks Application.compile_env(:phoenix_live_view, :enable_expensive_runtime_checks, false)
    def checks, do: @checks

    defmacro root, do: Application.get_env(:phoenix_live_view, :root_tag_attribute)

    defmacro annotations do
      {Application.get_env(:phoenix_live_view, :debug_heex_annotations, false),
       Application.get_env(:phoenix_live_view, :debug_attributes, false)}
    end
  end
  """

  @live_view_mix_exs """
  defmodule PhoenixLiveView.MixProject do
    use Mix.Project
    def project, do: [app: :phoenix_live_view, version: "1.2.13", deps: []]
    def application, do: [extra_applications: [:logger]]
  end
  """

  @comp """
  defmodule FxComp do
    require Phoenix.LiveView.FxRoot
    def tag, do: Phoenix.LiveView.FxRoot.root()
    def annotations, do: Phoenix.LiveView.FxRoot.annotations()
  end

  defmodule FxComp.Plain do
    def x, do: 1
  end
  """

  @deps %{
    "phoenix_live_view" => lib("phoenix_live_view", @live_view, %{mix_exs: @live_view_mix_exs}),
    "fx_comp" => lib("fx_comp", @comp, %{deps: ["phoenix_live_view"]})
  }

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-config-overlay-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)

    %{
      proj: TracerFixtures.project(Path.join(root, "a"), ["fx_comp"], @deps),
      other: TracerFixtures.project(Path.join(root, "b"), ["fx_comp"], @deps)
    }
  end

  test "with phx_dev's overlay the trace records the overlay's values", %{proj: proj} do
    put_overlay(proj, "phx_dev")

    verdict = judge!(proj, "fx_comp")
    assert verdict.status == :pass
    assert verdict.compile_env_rule == 1

    assert item(verdict, "phoenix_live_view", "root_tag_attribute") ==
             ConfigVariants.encode("phx-r")

    assert item(verdict, "phoenix_live_view", "enable_expensive_runtime_checks") ==
             ConfigVariants.encode(true)

    assert item(verdict, "phoenix_live_view", "debug_heex_annotations") ==
             ConfigVariants.encode(true)

    assert item(verdict, "phoenix_live_view", "debug_attributes") == ConfigVariants.encode(true)
    assert :ok = ConfigVariants.overlay_recorded("phx_dev", verdict.compile_env)
  end

  # The Mix VM loads `config/config.exs` before any traced compile: the
  # file is the project's own, and its read is neither a refusal nor an
  # observation of the package.
  test "the project's config/config.exs is not judged as a read of the host", %{proj: proj} do
    put_overlay(proj, "phx_dev")

    verdict = judge!(proj, "fx_comp")
    observations = verdict.verdict.observations
    assert observations["refusals"] == []
    assert observations["problems"] == []
    refute inspect(observations, limit: :infinity, printable_limit: :infinity) =~ "config.exs"
  end

  test "without an overlay the same keys record as unset", %{proj: proj} do
    verdict = judge!(proj, "fx_comp")
    assert item(verdict, "phoenix_live_view", "root_tag_attribute") == unset()

    assert ConfigVariants.wanted(ConfigVariants.reads(verdict.compile_env)) ==
             ["phx_prod", "phx_test", "phx_dev"]
  end

  test "the overlay changes exactly the code that reads it", %{proj: proj, other: other} do
    put_overlay(other, "phx_prod")
    _ = judge!(proj, "fx_comp")
    _ = judge!(other, "fx_comp")

    a = beams(proj, "fx_comp")
    b = beams(other, "fx_comp")
    assert Map.keys(a) == Map.keys(b)
    # The module that inlines the read differs; the one that reads nothing is identical.
    assert md5(a["Elixir.FxComp.beam"]) != md5(b["Elixir.FxComp.beam"])
    assert md5(a["Elixir.FxComp.Plain.beam"]) == md5(b["Elixir.FxComp.Plain.beam"])
  end

  test "R5 items never enter the .app; a package's own compile_env records the overlay's value",
       %{proj: proj} do
    put_overlay(proj, "phx_test")
    _ = judge!(proj, "fx_comp")

    {:ok, [{:application, :fx_comp, props}]} = :file.consult(app_path(proj, "fx_comp"))
    refute Keyword.has_key?(Keyword.get(props, :compile_env, []), :phoenix_live_view)

    {:ok, [{:application, :phoenix_live_view, lv}]} =
      :file.consult(app_path(proj, "phoenix_live_view"))

    assert {:phoenix_live_view, [:enable_expensive_runtime_checks], {:ok, true}} in Keyword.fetch!(
             lv,
             :compile_env
           )
  end

  # The overlay as the worker writes it (`NccWorker.ConfigOverlay`), less
  # the `import Config` line `put_config/2` adds.
  defp put_overlay(proj, name) do
    {:ok, overlay} = ConfigVariants.overlay(name)

    TracerFixtures.put_config(
      proj,
      String.replace_prefix(ConfigVariants.render(overlay), "import Config\n", "")
    )
  end

  # One traced compile of `package`, judged, and its `compile_env` and
  # `compile_env_rule` as the worker writes them into a toolchain build
  # (`Worker.r5_compile_env/2`), with the string keys a client and the
  # portal read.
  defp judge!(proj, package) do
    traced = TracerFixtures.trace(proj, [package])
    assert {:ok, 0} = traced.result, traced.log

    verdict = TracerFixtures.judge(proj, package, traced)
    assert verdict.status == :pass, inspect(verdict.observations, pretty: true)

    app_env = AppFile.read_compile_env(app_path(proj, package))
    {compile_env, rule} = Worker.r5_compile_env(app_env, verdict)

    %{
      status: verdict.status,
      verdict: verdict,
      compile_env: Enum.map(compile_env, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end)),
      compile_env_rule: rule
    }
  end

  defp item(verdict, app, key) do
    case Enum.find(verdict.compile_env, &(&1["app"] == app and &1["path"] == [key])) do
      %{"value" => value} -> value
      nil -> nil
    end
  end

  defp unset, do: ConfigReads.unset()

  defp beams(proj, app) do
    proj
    |> Path.join("_build/host/lib/#{app}/ebin/*.beam")
    |> Path.wildcard()
    |> Map.new(&{Path.basename(&1), File.read!(&1)})
  end

  defp md5(beam) do
    {:ok, {_module, md5}} = :beam_lib.md5(beam)
    md5
  end

  defp app_path(proj, app), do: Path.join(proj, "_build/host/lib/#{app}/ebin/#{app}.app")
end
