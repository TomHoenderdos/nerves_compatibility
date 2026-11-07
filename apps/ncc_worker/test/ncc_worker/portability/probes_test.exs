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

  defp frame(module, function, arity),
    do: %{"module" => module, "function" => function, "arity" => arity}

  defp probe(module, opts \\ []) do
    %{
      "channel" => "probe",
      "mfa" => Keyword.get(opts, :mfa, "code:ensure_loaded/1"),
      "arg" => Map.merge(%{"module" => module}, Keyword.get(opts, :arg, %{})),
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

  # Elixir's type checker looks a module up for the code it checks: what
  # it finds reaches only its warnings, unless a nested compile in the same
  # window captures them (`Code.with_diagnostics/1`).
  describe "a probe or call the type checker makes" do
    test "is dropped in a window with no nested compile", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"], "dep" => ["kernel"]})
      c = %{c | nested: %{"dep" => "Elixir.Code:eval_string/3"}}

      for event <- [
            probe("httpc", mfa: "erlang:module_loaded/1", arg: %{"checker" => true}),
            put_in(call("ssl", "ssl", "ssl:module_info/1"), ["arg", "checker"], true)
          ] do
        assert Probes.decide(event, c, "pkg") == :ignore
      end
    end

    test "counts in a window with a nested compile, which it names", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"]})
      c = %{c | nested: %{"pkg" => "Elixir.Code:with_diagnostics/2"}}
      event = probe("httpc", mfa: "erlang:module_loaded/1", arg: %{"checker" => true})

      assert Probes.decide(event, c, "pkg") ==
               {:unjudged,
                "compile-time probe of a module the trace loaded: httpc (inets) by " <>
                  "erlang:module_loaded/1, in a window with a nested compile " <>
                  "(Elixir.Code:with_diagnostics/2)"}

      call = put_in(call("ssl", "ssl", "ssl:module_info/1"), ["arg", "checker"], true)
      assert {:unjudged, why} = Probes.decide(call, c, "pkg")
      assert why =~ "nested compile (Elixir.Code:with_diagnostics/2)"
    end

    # The checker calls function_exported/3 only on a module it loaded
    # (CheckerLookupsTest), which an untraced compile loads too when its
    # application is on the path; module_loaded/1 it asks before loading.
    test "in a marked window, function_exported/3 of a module on the path is dropped",
         %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel", "inets"]})
      c = %{c | nested: %{"pkg" => "Elixir.Module:create/3"}}
      on_path = &probe("httpc", mfa: &1, arg: %{"checker" => true})

      assert Probes.decide(on_path.("erlang:function_exported/3"), c, "pkg") == :ignore
      assert {:unjudged, _} = Probes.decide(on_path.("erlang:module_loaded/1"), c, "pkg")

      off_path = probe("dbg", mfa: "erlang:function_exported/3", arg: %{"checker" => true})
      assert {:unjudged, why} = Probes.decide(off_path, c, "pkg")
      assert why =~ "nested compile (Elixir.Module:create/3)"
    end

    # cache_module/2 asks module_loaded/1 before loading, but for an Erlang
    # module on the path both of its branches cache the same entries
    # (CheckerLookupsTest).
    test "in a marked window, cache_module's module_loaded/1 of an Erlang module on the path is dropped",
         %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel", "inets"]})
      c = %{c | nested: %{"pkg" => "Elixir.Module:create/3"}}
      c = put_in(c.preloaded["Elixir.Version"], "inets")

      loaded = fn module, first, kind ->
        module
        |> probe(mfa: "erlang:module_loaded/1", arg: %{"checker" => true})
        |> Map.merge(%{"first" => first, "first_kind" => kind})
      end

      cache = frame("Elixir.Module.ParallelChecker", "-cache_module/2-fun-1-", 1)
      assert Probes.decide(loaded.("httpc", cache, "toolchain"), c, "pkg") == :ignore

      named = frame("Elixir.Module.ParallelChecker", "cache_module", 2)
      assert Probes.decide(loaded.("httpc", named, "toolchain"), c, "pkg") == :ignore

      other = frame("Elixir.Module.ParallelChecker", "fetch_export", 5)
      assert {:unjudged, _} = Probes.decide(loaded.("httpc", other, "toolchain"), c, "pkg")
      assert {:unjudged, _} = Probes.decide(loaded.("httpc", cache, "user"), c, "pkg")
      # Off the path, an Elixir module, a module with a checker chunk.
      assert {:unjudged, _} = Probes.decide(loaded.("dbg", cache, "toolchain"), c, "pkg")

      assert {:unjudged, _} =
               Probes.decide(loaded.("Elixir.Version", cache, "toolchain"), c, "pkg")
    end

    test "outside every window counts only when that is marked", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"]})
      event = probe("httpc", mfa: "erlang:module_loaded/1", arg: %{"checker" => true})
      assert Probes.decide(event, c, :outside) == :ignore
      c = %{c | nested: %{outside: "Elixir.Module:create/3"}}
      assert {:unjudged, _} = Probes.decide(event, c, :outside)
    end

    test "a probe that is not the checker's is judged as before", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"]})
      event = probe("httpc", mfa: "erlang:module_loaded/1", arg: %{"checker" => false})
      assert {:unjudged, _} = Probes.decide(event, c, "pkg")
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

  defp call(module, app, mfa),
    do: %{"channel" => "app_call", "mfa" => mfa, "arg" => %{"module" => module, "app" => app}}

  describe "a call into a module the trace loaded" do
    test "is judged unless its application is on the caller's path", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"], "child" => ["ssl"]})
      versions = call("ssl", "ssl", "ssl:versions/0")

      assert {:unjudged, "compile-time call into a module the trace loaded: ssl:versions/0 (ssl)"} =
               Probes.decide(versions, c, "pkg")

      assert Probes.decide(versions, c, "child") == :ignore
      c = put_in(c.deps["pkg"].children, ["child"])
      assert Probes.decide(versions, c, "pkg") == :ignore
    end

    test "outside a window, or into the tracer, is not judged", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["ssl"]})
      assert {:unjudged, _} = Probes.decide(call("ssl", "ssl", "ssl:versions/0"), c, :outside)

      assert {:unjudged, _} =
               Probes.decide(
                 call("ncc_tracer_digest", "ncc_tracer", "ncc_tracer_digest:dir/1"),
                 c,
                 "pkg"
               )
    end

    test "into an application always on the path is no concern", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => []})

      for app <- ~w(kernel stdlib elixir compiler logger),
          do: assert(Probes.decide(call("m", app, "m:f/0"), c, :outside) == :ignore)
    end
  end

  test "listing the loaded modules is never judged", %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => ["kernel"]})

    for mfa <- ~w(code:all_loaded/0 erlang:loaded/0 code:module_status/0
                  code:modified_modules/0) do
      event = %{"channel" => "loaded_modules", "mfa" => mfa, "arg" => %{}}

      assert Probes.decide(event, c, "pkg") ==
               {:unjudged, "compile-time list of the loaded modules: #{mfa}"}
    end
  end

  test "a malformed probe is not judged", %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => []})
    assert {:unjudged, _} = Probes.decide(%{"channel" => "probe", "arg" => %{}}, c, "pkg")
  end
end
