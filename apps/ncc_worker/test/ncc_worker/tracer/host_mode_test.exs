defmodule NccWorker.Tracer.HostModeTest do
  # Starts real `elixir` and `mix` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.{BuildIdentity, TracerFixtures, Tracer.Report}

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  # A macro dependency, a plain one with a priv file, a mix-built Erlang one
  # and the package.
  defp fixture(dir) do
    TracerFixtures.project(dir, ["fx_top"], %{
      "fx_top" => %{
        deps: ["fx_leaf", "fx_mac", "fx_erl"],
        files: %{
          "lib/fx_top.ex" => """
          defmodule FxTop do
            require FxMac
            @moduledoc "Top."
            def f, do: {FxLeaf.f(), FxMac.twice(21), :fx_erl.g()}
          end
          """
        }
      },
      "fx_leaf" => %{
        files: %{
          "lib/fx_leaf.ex" =>
            "defmodule FxLeaf do\n  @moduledoc \"Leaf.\"\n  @doc \"F.\"\n  def f, do: :ok\nend\n",
          "priv/data.txt" => "leaf data\n"
        }
      },
      "fx_mac" => %{
        files: %{
          "lib/fx_mac.ex" => """
          defmodule FxMac do
            defmacro twice(x), do: quote(do: unquote(x) * 2)
          end
          """
        }
      },
      "fx_erl" => %{
        files: %{"src/fx_erl.erl" => "-module(fx_erl).\n-export([g/0]).\ng() -> erl.\n"}
      }
    })
  end

  # Every published file of every built app: path => bytes.
  defp published(proj) do
    lib = Path.join([proj, "_build", "host", "lib"])

    for app <- File.ls!(lib),
        sub <- ["ebin", "priv"],
        root = Path.join([lib, app, sub]),
        rel <- Path.wildcard(Path.join(root, "**"), match_dot: true),
        File.regular?(rel),
        into: %{},
        do: {Path.relative_to(rel, lib), File.read!(rel)}
  end

  defp plain_compile(proj) do
    {out, status} =
      System.cmd("mix", ["compile"],
        cd: proj,
        env: TracerFixtures.env(proj),
        stderr_to_stdout: true
      )

    assert status == 0, out
  end

  # Identity in `NccWorker.BuildIdentity`'s sense: every file byte-equal,
  # except that a beam's Dbgi chunk only has to decode to `===` terms.
  test "the host-mode trace builds exactly what an untraced mix compile builds", %{tmp_dir: dir} do
    proj = fixture(dir)
    plain_compile(proj)
    untraced = published(proj)
    assert Map.has_key?(untraced, "fx_top/ebin/Elixir.FxTop.beam")
    assert Map.has_key?(untraced, "fx_erl/ebin/fx_erl.beam")
    assert Map.has_key?(untraced, "fx_leaf/priv/data.txt")
    assert Map.has_key?(untraced, "fixture_wrapper/ebin/fixture_wrapper.app")

    File.rm_rf!(Path.join(proj, "_build"))
    traced = TracerFixtures.trace(proj, ["fx_top"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    assert traced.report.problems == []
    assert Report.mode(traced.report) == :host

    host = published(proj)
    assert Enum.sort(Map.keys(host)) == Enum.sort(Map.keys(untraced))
    assert BuildIdentity.differences(host, untraced) == []
  end

  test "the project itself is compiled, after the last window", %{tmp_dir: dir} do
    proj = fixture(dir)
    traced = TracerFixtures.trace(proj, ["fx_top"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log

    wrapper = Path.join([proj, "_build", "host", "lib", "fixture_wrapper", "ebin"])
    assert File.regular?(Path.join(wrapper, "fixture_wrapper.app"))

    apps = Enum.map(traced.report.windows, & &1.app)
    assert Enum.sort(apps) == ["fx_erl", "fx_leaf", "fx_mac", "fx_top"]
    assert List.last(apps) == "fx_top"
    assert %{"status" => "ok", "final_sentinel" => true} = traced.report.ending
  end

  test "judge mode, the default, compiles the closure only", %{tmp_dir: dir} do
    proj = fixture(dir)
    traced = TracerFixtures.trace(proj, ["fx_top"])
    assert {:ok, 0} = traced.result, traced.log
    assert Report.mode(traced.report) == :judge
    refute File.exists?(Path.join([proj, "_build", "host", "lib", "fixture_wrapper"]))
  end

  test "a dependency already in _build is compiled again in its window", %{tmp_dir: dir} do
    proj = fixture(dir)
    stale = Path.join([proj, "_build", "host", "lib", "fx_leaf", "ebin"])
    File.mkdir_p!(stale)
    File.write!(Path.join(stale, "Elixir.Stale.beam"), "not a beam")

    traced = TracerFixtures.trace(proj, ["fx_top"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    refute File.exists?(Path.join(stale, "Elixir.Stale.beam"))
    assert "fx_leaf" in Enum.map(traced.report.windows, & &1.app)
  end

  test "a project that does not compile makes the host-mode trace exit non-zero", %{tmp_dir: dir} do
    proj = fixture(dir)
    File.mkdir_p!(Path.join(proj, "lib"))
    File.write!(Path.join(proj, "lib/broken.ex"), "defmodule Broken do\n  def f, do: \nend\n")

    traced = TracerFixtures.trace(proj, ["fx_top"], mode: :host)
    assert {:ok, status} = traced.result
    assert status != 0
    assert traced.report.ending["status"] == "compile_failed"
  end
end
