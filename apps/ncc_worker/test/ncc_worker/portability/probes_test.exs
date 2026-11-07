defmodule NccWorker.Portability.ProbesTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability.{Context, Probes}

  @moduletag :tmp_dir

  defp ctx(dir, apps) do
    deps =
      Map.new(apps, fn {app, applications} ->
        build = Path.join([dir, "_build", "host", "lib", app])
        File.mkdir_p!(Path.join(build, "ebin"))
        list = Enum.map_join(applications, ",", & &1)

        File.write!(
          Path.join([build, "ebin", "#{app}.app"]),
          "{application,#{app},[{applications,[#{list}]}]}.\n"
        )

        {app,
         %{build: build, dest: nil, manager: "mix", children: [], native?: false, hex_files: nil}}
      end)

    %Context{
      package: "pkg",
      deps: deps,
      preloaded: %{
        "dbg" => "runtime_tools",
        "httpc" => "inets",
        "ssl" => "ssl",
        "json" => "stdlib",
        "ncc_tracer_digest" => "ncc_tracer"
      }
    }
  end

  defp frame(module, function \\ "f", arity \\ 0),
    do: %{"module" => module, "function" => function, "arity" => arity}

  defp probe(module, opts \\ []) do
    %{
      "channel" => "probe",
      "mfa" => Keyword.get(opts, :mfa, "code:ensure_loaded/1"),
      "arg" =>
        Map.merge(
          %{
            "module" => module,
            "by" => Keyword.get(opts, :by, frame("Elixir.Pkg")),
            "by_kind" => Keyword.get(opts, :by_kind, "user")
          },
          Keyword.get(opts, :arg, %{})
        ),
      "caller" => Keyword.get(opts, :caller, frame("Elixir.Code", "ensure_loaded?", 1))
    }
  end

  test "a module the trace did not load is no concern", %{tmp_dir: dir} do
    assert Probes.decide(probe("lists"), ctx(dir, %{"pkg" => []}), "pkg") == :ignore
  end

  test "an application the owner lists, directly or through one it lists", %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => ["kernel", "inets"]})
    assert Probes.decide(probe("httpc"), c, "pkg") == :ignore
    # inets lists ssl only optionally; ssl is not on pkg's path.
    assert {:unjudged, "compile-time probe of a module the trace loaded: ssl (ssl)"} =
             Probes.decide(probe("ssl"), c, "pkg")
  end

  test "an application a closure dependency lists", %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => ["kernel"], "child" => ["runtime_tools"]})
    c = put_in(c.deps["pkg"].children, ["child"])
    assert Probes.decide(probe("dbg"), c, "pkg") == :ignore
  end

  test "an application nothing on the path lists, or no owner", %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => ["kernel"]})
    assert {:unjudged, _} = Probes.decide(probe("dbg"), c, "pkg")
    assert {:unjudged, _} = Probes.decide(probe("dbg"), c, :outside)
    assert {:unjudged, _} = Probes.decide(probe("dbg"), c, "not_a_dep")
  end

  test "kernel, stdlib and elixir are on every path, outside a window too", %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => []})
    assert Probes.decide(probe("json"), c, "pkg") == :ignore
    assert Probes.decide(probe("json"), c, :outside) == :ignore
    assert Probes.decide(probe("json", mfa: "code:which/1"), c, :outside) == :ignore
    assert Probes.decide(probe("json", mfa: "code:get_object_code/1"), c, "pkg") == :ignore
  end

  test "a loaded-module probe is never judged, whatever the path", %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => ["kernel", "inets"]})

    for mfa <- ~w(code:is_loaded/1 code:module_status/1 erlang:module_loaded/1
                  erlang:function_exported/3) do
      assert {:unjudged, why} = Probes.decide(probe("httpc", mfa: mfa), c, "pkg")
      assert why == "compile-time probe of a module the trace loaded: httpc (inets) by #{mfa}"
      assert {:unjudged, _} = Probes.decide(probe("json", mfa: mfa), c, :outside)
    end
  end

  test "a probe the code server makes inside a traced probe is that probe's", %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => ["kernel"]})

    for fun <- ~w(ensure_loaded is_loaded which module_status get_object_code) do
      nested = probe("dbg", mfa: "erlang:module_loaded/1", caller: frame("code", fun, 1))
      assert Probes.decide(nested, c, "pkg") == :ignore
    end

    other = probe("dbg", mfa: "erlang:module_loaded/1", caller: frame("code", "load_file", 1))
    assert {:unjudged, _} = Probes.decide(other, c, "pkg")
  end

  test "the type checker's own lookups are dropped", %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => ["kernel"]})

    for module <- ~w(Elixir.Module.ParallelChecker Elixir.Module.Types.Apply) do
      checker =
        probe("httpc", mfa: "erlang:module_loaded/1", by: frame(module), by_kind: "toolchain")

      assert Probes.decide(checker, c, "pkg") == :ignore
    end

    # A package's module of the same name is the package's.
    fake =
      probe("httpc", by: frame("Elixir.Module.Types.Apply"), by_kind: "user")

    assert {:unjudged, _} = Probes.decide(fake, c, "pkg")
  end

  test "any other first frame is judged, the toolchain's too", %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => ["kernel"]})

    for {by, kind} <- [
          {frame("Elixir.Kernel.ParallelCompiler"), "toolchain"},
          {frame("elixir_module", "expand_callback", 6), "dispatcher"},
          {nil, "none"}
        ] do
      assert {:unjudged, _} = Probes.decide(probe("httpc", by: by, by_kind: kind), c, "pkg")
    end
  end

  test "the tracer's own modules are on no path", %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => ["kernel"]})

    assert {:unjudged,
            "compile-time probe of a module the trace loaded: " <>
              "ncc_tracer_digest (ncc_tracer)"} =
             Probes.decide(probe("ncc_tracer_digest"), c, "pkg")
  end

  test "a child VM's probe names its own application", %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => ["kernel", "inets"]})
    assert Probes.decide(probe("httpc_cookie", arg: %{"app" => "inets"}), c, "pkg") == :ignore

    assert {:unjudged, _} =
             Probes.decide(probe("public_key", arg: %{"app" => "public_key"}), c, "pkg")
  end

  test "a malformed probe is not judged", %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => []})
    assert {:unjudged, _} = Probes.decide(%{"channel" => "probe", "arg" => %{}}, c, "pkg")
  end
end
