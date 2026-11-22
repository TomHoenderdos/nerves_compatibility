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

  # `Code.ensure_loaded?(:json) and function_exported?(:json, f, a)`: the
  # ensure_loaded loads :json untraced too (stdlib is on every path), so by
  # the time the same process asks function_exported/3 the module is loaded
  # either way and the answer is the same.
  describe "function_exported/3 after the same process ensure-loaded the module" do
    defp at(event, pid, ts),
      do: Map.merge(event, %{"pid" => pid, "ts" => ts, "extent" => "frame"})

    defp ensured(c, owned), do: %{c | ensured: Probes.ensured(owned)}

    test "is the same answer in that process's window", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"], "dep" => ["kernel"]})
      loaded = probe("json") |> at("<0.10.0>", 100)
      exported = probe("json", mfa: "erlang:function_exported/3") |> at("<0.10.0>", 200)

      assert {:unjudged, _} = Probes.decide(exported, c, "pkg")
      c = ensured(c, [{"pkg", loaded}])
      assert Probes.decide(exported, c, "pkg") == :ignore

      # A closure dependency's window is judged the same way.
      assert Probes.decide(exported, ensured(c, [{"dep", loaded}]), "dep") == :ignore
    end

    test "is judged when anything else differs", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"], "dep" => ["kernel"]})
      loaded = probe("json") |> at("<0.10.0>", 100)
      exported = probe("json", mfa: "erlang:function_exported/3") |> at("<0.10.0>", 200)

      cases = [
        # Another process, the same instant, later, another window, another module.
        {[{"pkg", at(loaded, "<0.11.0>", 100)}], exported, "pkg"},
        {[{"pkg", at(loaded, "<0.10.0>", 200)}], exported, "pkg"},
        {[{"pkg", at(loaded, "<0.10.0>", 300)}], exported, "pkg"},
        {[{"dep", loaded}], exported, "pkg"},
        {[{"pkg", probe("dbg") |> at("<0.10.0>", 100)}], exported, "pkg"},
        # Not an ensure_loaded: which/1 and get_object_code/1 load nothing.
        {[{"pkg", probe("json", mfa: "code:which/1") |> at("<0.10.0>", 100)}], exported, "pkg"},
        {[{"pkg", probe("json", mfa: "code:get_object_code/1") |> at("<0.10.0>", 100)}], exported,
         "pkg"},
        # The checker's own lookups, or an unjudged stack.
        {[{"pkg", put_in(loaded, ["arg", "checker"], true)}], exported, "pkg"},
        {[{"pkg", Map.put(loaded, "extent", "unjudged")}], exported, "pkg"},
        # No window: nobody's package or closure.
        {[{:outside, loaded}], exported, :outside},
        # No pid or no time on either.
        {[{"pkg", Map.delete(loaded, "pid")}], Map.delete(exported, "pid"), "pkg"},
        {[{"pkg", Map.delete(loaded, "ts")}], exported, "pkg"},
        {[{"pkg", loaded}], Map.delete(exported, "ts"), "pkg"}
      ]

      for {owned, event, owner} <- cases do
        assert {:unjudged, _} = Probes.decide(event, ensured(c, owned), owner),
               inspect({owned, event, owner})
      end
    end

    test "only for a module on the owner's path, never the tracer's", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel", "inets"]})

      for {module, verdict} <- [
            {"httpc", :ignore},
            {"dbg", :unjudged},
            {"ncc_tracer_digest", :unjudged}
          ] do
        loaded = probe(module) |> at("<0.10.0>", 100)
        exported = probe(module, mfa: "erlang:function_exported/3") |> at("<0.10.0>", 200)
        decision = Probes.decide(exported, ensured(c, [{"pkg", loaded}]), "pkg")
        assert if(decision == :ignore, do: :ignore, else: elem(decision, 0)) == verdict, module
      end
    end

    test "only function_exported/3: the other loaded-now probes stay judged", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"]})
      c = ensured(c, [{"pkg", probe("json") |> at("<0.10.0>", 100)}])

      for mfa <- ~w(code:is_loaded/1 code:module_status/1 erlang:module_loaded/1) do
        event = probe("json", mfa: mfa) |> at("<0.10.0>", 200)
        assert {:unjudged, _} = Probes.decide(event, c, "pkg"), mfa
      end
    end
  end

  test "a probe the code server makes inside a traced probe is that probe's", %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => ["kernel"]})

    for fun <- ~w(ensure_loaded is_loaded which module_status get_object_code) do
      nested = probe("dbg", mfa: "erlang:module_loaded/1", caller: frame("code", fun, 1))
      assert Probes.decide(nested, c, "pkg") == :ignore
    end

    other = probe("dbg", mfa: "erlang:module_loaded/1", caller: frame("code", "purge", 1))
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

    for mfa <- ~w(code:which/1 erlang:function_exported/3) do
      assert {:unjudged, _} = Probes.decide(probe("ncc_tracer_digest", mfa: mfa), c, "pkg")
    end
  end

  # Coverage drop 2026-11-22, F1: `Exception.format_application/1` of a
  # stack frame in the driver's process. The tracer loads no application, so
  # no loaded application lists its modules: the controller's answer is
  # `undefined` traced, and untraced too.
  test "the application controller's lookup of a tracer module is the same answer",
       %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => ["kernel"]})

    lookup =
      probe("ncc_tracer_digest",
        mfa: "application_controller:get_application_module/1",
        caller: frame("Elixir.Exception", "format_application", 1),
        arg: %{"by_package" => false}
      )

    assert Probes.decide(lookup, c, "pkg") == :ignore
    assert Probes.decide(lookup, c, :outside) == :ignore
    by_package = put_in(lookup, ["arg", "by_package"], true)
    assert Probes.decide(by_package, c, "pkg") == :ignore
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

    # OTP's public_key decodes and encodes certificates through asn1rt_nif
    # while a compile downloads over HTTPS, in ssl's own connection process.
    # Untraced, the same installed OTP code makes the same call: public_key's
    # .app lists asn1, so asn1 is on the path wherever public_key runs.
    test "from installed OTP code whose .app lists the application is no concern",
         %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"]})

      for mfa <- ~w(asn1rt_nif:encode_ber_tlv/1 asn1rt_nif:decode_ber_tlv/1),
          owner <- ["pkg", :outside] do
        event = put_in(call("asn1rt_nif", "asn1", mfa)["arg"]["caller_app"], "public_key")
        assert Probes.decide(event, c, owner) == :ignore, "#{mfa} #{inspect(owner)}"
      end
    end

    test "from any other caller it is judged", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"]})
      encode = call("asn1rt_nif", "asn1", "asn1rt_nif:encode_ber_tlv/1")
      by = fn event, caller -> put_in(event["arg"]["caller_app"], caller) end
      why = "compile-time call into a module the trace loaded: "

      # No caller application (package code, a module loaded from anywhere
      # but OTP's lib dir, no frame), or one the tracer could not name.
      for event <- [encode, by.(encode, nil), by.(encode, 7)] do
        assert {:unjudged, ^why <> "asn1rt_nif:encode_ber_tlv/1 (asn1)"} =
                 Probes.decide(event, c, :outside)
      end

      # An application that does not list asn1 itself: ssl lists public_key,
      # which lists asn1, but only a direct listing counts.
      for caller <- ~w(ssl inets crypto asn1 kernel) do
        assert {:unjudged, _} = Probes.decide(by.(encode, caller), c, :outside), caller
      end

      # A name that is no installed OTP application, or an Elixir one.
      for caller <- ~w(no_such_otp_app pkg ncc_tracer mix elixir) do
        assert {:unjudged, _} = Probes.decide(by.(encode, caller), c, :outside), caller
      end

      # public_key lists asn1 and crypto, never inets or the tracer.
      for {module, app, mfa} <- [
            {"httpc", "inets", "httpc:request/4"},
            {"ncc_tracer_digest", "ncc_tracer", "ncc_tracer_digest:dir/1"}
          ] do
        event = by.(call(module, app, mfa), "public_key")
        assert {:unjudged, ^why <> _} = Probes.decide(event, c, :outside), mfa
      end
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

  # Mix compiles a dependency on a code path pruned to the applications its
  # closure lists; Mix.install does not prune (`prune_code_paths: false`).
  # The tracer names the installed OTP or Elixir application of a module it
  # did not load (`otp_app`): a probe of one off the owner's path answers
  # differently there (vega_lite 0.1.11's `Code.ensure_loaded?(:wx)`).
  describe "a probe of an installed application's module the trace did not load" do
    defp otp(module, app, opts \\ []),
      do:
        probe(
          module,
          Keyword.update(opts, :arg, %{"otp_app" => app}, &Map.put(&1, "otp_app", app))
        )

    # S10: no closure application lists wx, so nothing in the build could
    # load it and the builder's answer is "absent"; client 0.9 hits only
    # where wx is not installed at all.
    test "is recorded off the owner's path, by every probe function", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel", "inets"]})

      assert Probes.decide(otp("wx", "wx"), c, "pkg") ==
               {:observe, "probe_inputs",
                %{
                  "of" => "otp_app",
                  "name" => "wx",
                  "via" => "Code.ensure_loaded?/1",
                  "refusal" =>
                    "compile-time probe of an OTP application outside the closure: " <>
                      "wx via Code.ensure_loaded?/1"
                }}

      for mfa <- ~w(code:which/1 code:get_object_code/1 code:is_loaded/1 code:module_status/1
                    erlang:module_loaded/1 erlang:function_exported/3) do
        event = otp("wxWebView", "wx", mfa: mfa, caller: frame("Elixir.FxProbe", "f", 0))

        assert {:observe, "probe_inputs", %{"of" => "otp_app", "name" => "wx"} = item} =
                 Probes.decide(event, c, "pkg")

        assert item["refusal"] ==
                 "compile-time probe of an OTP application outside the closure: wx via #{mfa}"
      end
    end

    # eex ships with Elixir: installed wherever Elixir is, so no client could
    # take a build that records it. Refused as before.
    test "of an Elixir application is refused", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"]})

      assert Probes.decide(otp("Elixir.EEx", "eex"), c, "pkg") ==
               {:refuse,
                "compile-time probe of an OTP application outside the closure: " <>
                  "eex via Code.ensure_loaded?/1"}
    end

    # Another closure application lists wx: its compile may have loaded wx's
    # modules before the owner's probe, so the builder's own answer is not
    # known.
    test "is refused when another closure application lists it", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"], "child" => ["kernel"], "other" => ["wx"]})
      c = put_in(c.deps["pkg"].children, ["child", "other"])

      assert Probes.decide(otp("wx", "wx"), c, "child") ==
               {:refuse,
                "compile-time probe of an OTP application outside the closure: " <>
                  "wx via Code.ensure_loaded?/1"}
    end

    test "names the Elixir function the package called", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => []})

      for {caller, via} <- [
            {frame("Elixir.Code", "ensure_compiled", 2), "Code.ensure_compiled/2"},
            {frame("Elixir.Kernel", "macro_exported?", 3), "Kernel.macro_exported?/3"},
            {frame("elixir_compiler_1", "__MODULE__", 1), "code:ensure_loaded/1"},
            {nil, "code:ensure_loaded/1"}
          ] do
        assert {:observe, "probe_inputs", %{"via" => ^via, "refusal" => why}} =
                 Probes.decide(otp("mnesia", "mnesia", caller: caller), c, "pkg")

        assert String.ends_with?(why, ": mnesia via " <> via), why
      end
    end

    test "is no concern on the owner's path", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel", "mnesia"], "child" => ["wx"]})
      assert Probes.decide(otp("mnesia", "mnesia"), c, "pkg") == :ignore
      assert Probes.decide(otp("mnesia_lib", "mnesia", mfa: "code:which/1"), c, "pkg") == :ignore

      # Through a closure dependency's own list, and through an installed
      # application's (ssl lists public_key).
      assert {:observe, "probe_inputs", _} = Probes.decide(otp("wx", "wx"), c, "pkg")
      c = put_in(c.deps["pkg"].children, ["child"])
      assert Probes.decide(otp("wx", "wx"), c, "pkg") == :ignore

      c = ctx(dir, %{"pkg" => ["ssl"]})
      assert Probes.decide(otp("public_key", "public_key"), c, "pkg") == :ignore
    end

    test "of an application on every compile's path is no concern", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => []})

      for app <- ~w(kernel stdlib compiler erts elixir mix iex ex_unit logger),
          do: assert(Probes.decide(otp("m", app), c, :outside) == :ignore, app)
    end

    # Round-2 ruling 3 (R1-A): a module of an application on every path
    # that was not loaded when the trace started can be found the same way
    # anywhere, but whether it is loaded now is what other compile-time
    # code in the VM did: `function_exported?(URI, :new, 1)` alone builds
    # `false`, and `true` after an earlier dependency used URI.
    test "an every-path module's loaded-now probe refuses unless ensured first", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"]})

      pkg =
        &otp("Elixir.URI", "elixir",
          mfa: &1,
          caller: frame("Elixir.Pkg", "f", 0),
          arg: %{"by_package" => true}
        )

      assert Probes.decide(pkg.("erlang:function_exported/3"), c, "pkg") ==
               {:refuse,
                "compile-time probe of whether a module is loaded: Elixir.URI via erlang:function_exported/3"}

      assert {:refuse, _} = Probes.decide(pkg.("erlang:module_loaded/1"), c, :outside)
      # Whether it can be found, by the package or the toolchain, anywhere.
      assert Probes.decide(pkg.("code:ensure_loaded/1"), c, "pkg") == :ignore
      assert Probes.decide(pkg.("code:which/1"), c, :outside) == :ignore

      toolchain = put_in(pkg.("erlang:function_exported/3"), ["arg", "by_package"], false)
      assert Probes.decide(toolchain, c, "pkg") == :ignore

      loaded = "code:ensure_loaded/1" |> pkg.() |> at("<0.10.0>", 100)
      exported = "erlang:function_exported/3" |> pkg.() |> at("<0.10.0>", 200)

      assert Probes.decide(exported, %{c | ensured: Probes.ensured([{"pkg", loaded}])}, "pkg") ==
               :ignore
    end

    test "is refused outside every window, or for no closure dependency", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["mnesia"]})
      assert {:refuse, _} = Probes.decide(otp("mnesia", "mnesia"), c, :outside)
      assert {:refuse, _} = Probes.decide(otp("mnesia", "mnesia"), c, "not_a_dep")
    end

    # A dependency's mix.exs runs on whatever code path Mix left: the full
    # one while Mix loads the dependencies, the previous dependency's pruned
    # one when compile.all asks its application/0 (easel 0.3.4's
    # `optional_apps/0`), and the full one under Mix.install.
    test "is refused from a closure dependency's mix.exs, listed or not", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel", "wx"]})
      File.mkdir_p!(Path.join(dir, "deps/pkg"))
      dest = Context.realpath(Path.join(dir, "deps/pkg"))
      File.write!(Path.join(dest, "mix.exs"), "")
      c = put_in(c.deps["pkg"].dest, dest)

      in_mix_exs =
        "wx"
        |> otp("wx", caller: frame("Elixir.Code", "ensure_compiled", 2))
        |> Map.put("user", %{"file" => Path.join(dest, "mix.exs"), "line" => 30})

      assert Probes.decide(in_mix_exs, c, "pkg") ==
               {:refuse,
                "compile-time probe of an OTP application outside the closure: " <>
                  "wx via Code.ensure_compiled/2 in mix.exs"}

      in_lib = put_in(in_mix_exs["user"]["file"], Path.join(dest, "lib/pkg.ex"))
      assert Probes.decide(in_lib, c, "pkg") == :ignore
    end

    test "the attribute lookup @behaviour makes is no concern", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => []})
      event = otp("wx_object", "wx", arg: %{"attribute" => true})
      assert Probes.decide(event, c, "pkg") == :ignore

      assert {:observe, "probe_inputs", _} =
               Probes.decide(otp("wx_object", "wx", arg: %{"attribute" => false}), c, "pkg")

      # Only the code:ensure_loaded/1 that lookup is.
      other = otp("wx_object", "wx", mfa: "code:which/1", arg: %{"attribute" => true})
      assert {:observe, "probe_inputs", _} = Probes.decide(other, c, "pkg")
    end

    test "inside a traced probe, it is that probe's", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => []})
      nested = otp("wx", "wx", mfa: "erlang:module_loaded/1", caller: frame("code", "which", 1))
      assert Probes.decide(nested, c, "pkg") == :ignore
    end

    test "by the type checker, counts only in a window with a nested compile", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => []})
      event = otp("wx", "wx", arg: %{"checker" => true})
      assert Probes.decide(event, c, "pkg") == :ignore

      c = %{c | nested: %{"pkg" => "Elixir.Code:with_diagnostics/2"}}

      assert Probes.decide(event, c, "pkg") ==
               {:observe, "probe_inputs",
                %{
                  "of" => "otp_app",
                  "name" => "wx",
                  "via" => "Code.ensure_loaded?/1",
                  "refusal" =>
                    "compile-time probe of an OTP application outside the closure: wx via " <>
                      "Code.ensure_loaded?/1, in a window with a nested compile " <>
                      "(Elixir.Code:with_diagnostics/2)"
                }}

      # A refusal there keeps its suffix: another closure application lists wx.
      c = ctx(dir, %{"pkg" => ["kernel"], "third" => ["kernel"], "other" => ["wx"]})
      c = put_in(c.deps["pkg"].children, ["third", "other"])
      c = %{c | nested: %{"third" => "x:y/1"}}

      assert {:refuse, why} = Probes.decide(event, c, "third")
      assert why =~ "wx via Code.ensure_loaded?/1, in a window with a nested compile (x:y/1)"
    end

    # The trace's own load makes its answer wrong whatever the path: that
    # stays could-not-judge.
    test "a module the trace loaded is judged as such", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => []})

      assert {:unjudged, "compile-time probe of a module the trace loaded: dbg (runtime_tools)"} =
               Probes.decide(otp("dbg", "runtime_tools"), c, "pkg")
    end

    test "the refusal is a trace refusal that withdraws" do
      assert Compatibility.Portability.refusal?(
               "compile-time probe of an OTP application outside the closure: wx via x"
             )

      assert Compatibility.Portability.withdraws?(
               "compile-time probe of an OTP application outside the closure: wx via x"
             )
    end
  end

  # What the application controller knows of an application (loaded,
  # its keys, running, started, loaded now): Mix loads every closure
  # application of a dependency before compiling it (Mix.AppLoader), and
  # nothing unloads one, so the answer for an application off the owner's
  # path is whatever earlier compiles loaded, and under Mix.install whatever
  # the whole install holds.
  describe "an application probe" do
    defp app_probe(app, opts \\ []) do
      %{
        "channel" => "app_probe",
        "mfa" => Keyword.get(opts, :mfa, "application_controller:get_key/2"),
        "arg" => Map.merge(%{"app" => app}, Keyword.get(opts, :arg, %{})),
        "caller" => Keyword.get(opts, :caller, frame("Elixir.Application", "spec", 2))
      }
    end

    test "of an application on the owner's path is no concern", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel", "mnesia"], "child" => ["kernel"]})
      c = put_in(c.deps["pkg"].children, ["child"])

      for app <- ~w(pkg child mnesia kernel stdlib elixir logger),
          mfa <- ~w(application_controller:get_key/2 application_controller:load_application/1),
          do: assert(Probes.decide(app_probe(app, mfa: mfa), c, "pkg") == :ignore, app)
    end

    # S10: an application no package of the build is, and an OTP one no
    # closure application lists, are recorded; client 0.9 checks them.
    test "of any other application is recorded, an OTP one as such", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"]})

      assert Probes.decide(app_probe("mnesia", arg: %{"otp_app" => "mnesia"}), c, "pkg") ==
               {:observe, "probe_inputs",
                %{
                  "of" => "otp_app",
                  "name" => "mnesia",
                  "via" => "Application.spec/2",
                  "refusal" =>
                    "compile-time probe of an OTP application outside the closure: " <>
                      "mnesia via Application.spec/2"
                }}

      assert Probes.decide(app_probe("phoenix_html"), c, "pkg") ==
               {:observe, "probe_inputs",
                %{
                  "of" => "app",
                  "name" => "phoenix_html",
                  "via" => "Application.spec/2",
                  "refusal" =>
                    "compile-time probe of a dependency outside the closure: " <>
                      "phoenix_html via Application.spec/2"
                }}

      load =
        app_probe("mnesia",
          mfa: "application_controller:load_application/1",
          caller: frame("application", "load1", 2),
          arg: %{"otp_app" => "mnesia"}
        )

      assert {:observe, "probe_inputs", %{"refusal" => why}} = Probes.decide(load, c, "pkg")
      assert why =~ "mnesia via application_controller:load_application/1"
      assert {:refuse, _} = Probes.decide(app_probe("mnesia"), c, :outside)
      assert {:refuse, _} = Probes.decide(app_probe("phoenix_html"), c, "not_a_dep")
    end

    # Whether the owner's compile finds a build application outside its own
    # closure, or an OTP one another closure application lists, is Mix's
    # compile order: refused.
    test "of a build application outside the owner's path refuses", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"], "child" => ["kernel"], "other" => ["mnesia"]})
      c = put_in(c.deps["pkg"].children, ["child", "other"])

      assert Probes.decide(app_probe("other"), c, "child") ==
               {:refuse,
                "compile-time probe of a dependency outside the closure: " <>
                  "other via Application.spec/2"}

      assert {:refuse, _} =
               Probes.decide(app_probe("mnesia", arg: %{"otp_app" => "mnesia"}), c, "child")
    end

    test "from a closure dependency's mix.exs refuses, listed or not", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel", "mnesia"]})
      File.mkdir_p!(Path.join(dir, "deps/pkg"))
      dest = Context.realpath(Path.join(dir, "deps/pkg"))
      File.write!(Path.join(dest, "mix.exs"), "")
      c = put_in(c.deps["pkg"].dest, dest)

      event =
        "mnesia"
        |> app_probe(arg: %{"otp_app" => "mnesia"})
        |> Map.put("user", %{"file" => Path.join(dest, "mix.exs")})

      assert {:refuse, why} = Probes.decide(event, c, "pkg")
      assert String.ends_with?(why, " in mix.exs")

      # Of an application on every path it stays no concern.
      assert Probes.decide(Map.put(app_probe("elixir"), "user", event["user"]), c, "pkg") ==
               :ignore
    end

    # Loaded before the tracer started (Hex starts ssl and inets): loaded
    # either way, as a module loaded then is.
    test "of an application loaded before the trace is no concern", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"]})
      event = app_probe("ssl", arg: %{"otp_app" => "ssl", "loaded_before" => true})
      assert Probes.decide(event, c, "pkg") == :ignore

      assert {:observe, "probe_inputs", _} =
               Probes.decide(put_in(event["arg"]["loaded_before"], false), c, "pkg")
    end

    test "is unreadable without an application name", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => []})
      assert {:unjudged, _} = Probes.decide(%{"channel" => "app_probe", "arg" => %{}}, c, "pkg")
    end
  end

  test "a where_is_file of a module's beam is a path probe", %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => ["kernel", "inets"]})
    on_path = otp_event("mnesia_lib", "mnesia", "code:where_is_file/1")
    assert {:observe, "probe_inputs", %{"of" => "otp_app"}} = Probes.decide(on_path, c, "pkg")
    c = ctx(dir, %{"pkg" => ["kernel", "mnesia"]})
    assert Probes.decide(on_path, c, "pkg") == :ignore
  end

  defp otp_event(module, app, mfa) do
    %{
      "channel" => "probe",
      "mfa" => mfa,
      "arg" => %{"module" => module, "otp_app" => app},
      "caller" => frame("elixir_compiler_1", "__MODULE__", 1)
    }
  end

  # A probe the package made (the tracer's `by_package`) of a module that is
  # no installed OTP or Elixir one and that the trace did not load: under
  # Mix.install every installed dependency is on the code path, and in a
  # Mix project a module an earlier dependency's compile loaded stays
  # loaded, so only a module the owner's closure holds answers the same.
  describe "a package's probe of a dependency's module" do
    defp hex(module, opts \\ []) do
      arg = Map.merge(%{"by_package" => true}, Keyword.get(opts, :arg, %{}))
      probe(module, Keyword.put(opts, :arg, arg))
    end

    defp with_modules(c, modules), do: %{c | modules: modules}

    # S10: nothing in the build defines it, so the builder's answer is
    # "absent"; recorded for client 0.9, which misses where the user's
    # project can supply the module.
    test "of a module nothing in the build defines is recorded", %{tmp_dir: dir} do
      c =
        dir
        |> ctx(%{"pkg" => ["kernel"], "child" => ["kernel"], "other" => ["kernel"]})
        |> with_modules(%{"Elixir.Other" => "other", "Elixir.Child" => "child"})

      assert Probes.decide(hex("Elixir.Phoenix.HTML.Safe"), c, "pkg") ==
               {:observe, "probe_inputs",
                %{
                  "of" => "module",
                  "name" => "Elixir.Phoenix.HTML.Safe",
                  "definers" => [],
                  "via" => "Code.ensure_loaded?/1",
                  "refusal" =>
                    "compile-time probe of a dependency outside the closure: " <>
                      "Elixir.Phoenix.HTML.Safe via Code.ensure_loaded?/1"
                }}

      # Every probe function: the module is on no path and loaded nowhere.
      for mfa <- ~w(code:which/1 erlang:function_exported/3 erlang:module_loaded/1) do
        assert {:observe, "probe_inputs", %{"name" => "Elixir.Poison"}} =
                 Probes.decide(hex("Elixir.Poison", mfa: mfa), c, "pkg")
      end

      # Outside every window, or for no closure dependency, it refuses.
      assert {:refuse, _} = Probes.decide(hex("Elixir.Poison"), c, :outside)
      assert {:refuse, _} = Probes.decide(hex("Elixir.Poison"), c, "not_a_dep")
    end

    # Built, but not in the owner's closure: whether the owner's compile
    # finds it is Mix's compile order (a module an earlier dependency's
    # compile loaded stays loaded), and Mix.install finds it.
    test "of a module another build application defines refuses", %{tmp_dir: dir} do
      c =
        dir
        |> ctx(%{"pkg" => ["kernel"], "child" => ["kernel"], "other" => ["kernel"]})
        |> with_modules(%{"Elixir.Other" => "other", "Elixir.Child" => "child"})

      assert Probes.decide(hex("Elixir.Other"), c, "pkg") ==
               {:refuse,
                "compile-time probe of a dependency outside the closure: " <>
                  "Elixir.Other via Code.ensure_loaded?/1"}

      c = put_in(c.deps["pkg"].children, ["child"])
      assert Probes.decide(hex("Elixir.Child"), c, "pkg") == :ignore
      assert {:refuse, _} = Probes.decide(hex("Elixir.Child"), c, :outside)
    end

    test "of the owner's own module, or a closure dependency's, by a path probe passes",
         %{tmp_dir: dir} do
      c = dir |> ctx(%{"pkg" => ["kernel"]}) |> with_modules(%{"Elixir.Pkg.Other" => "pkg"})

      for mfa <-
            ~w(code:ensure_loaded/1 code:which/1 code:get_object_code/1 code:where_is_file/1 code:load_file/1),
          do: assert(Probes.decide(hex("Elixir.Pkg.Other", mfa: mfa), c, "pkg") == :ignore, mfa)
    end

    # Whether it is loaded now: what other compile-time code in the same VM
    # ran decides it (a call into a module loads it), and the user's project
    # decides that, not the builder's.
    test "of a closure dependency's module by a loaded-now probe refuses unless ensured first",
         %{tmp_dir: dir} do
      c =
        dir
        |> ctx(%{"pkg" => ["kernel"], "dep" => ["kernel"]})
        |> with_modules(%{"Elixir.Dep.Other" => "dep"})

      c = put_in(c.deps["pkg"].children, ["dep"])

      for mfa <- ~w(code:is_loaded/1 code:module_status/1 erlang:module_loaded/1
                    erlang:function_exported/3) do
        event = hex("Elixir.Dep.Other", mfa: mfa, caller: frame("Elixir.Pkg", "f", 0))

        assert Probes.decide(event, c, "pkg") ==
                 {:refuse,
                  "compile-time probe of whether a module is loaded: Elixir.Dep.Other via #{mfa}"}
      end

      loaded = hex("Elixir.Dep.Other") |> at("<0.10.0>", 100)
      exported = hex("Elixir.Dep.Other", mfa: "erlang:function_exported/3") |> at("<0.10.0>", 200)
      c = %{c | ensured: Probes.ensured([{"pkg", loaded}])}
      assert Probes.decide(exported, c, "pkg") == :ignore
    end

    # Round 3, R2-2: the owner's own module is no exception. Whether it is
    # loaded at the probe is whether another file's compile-time code called
    # into it first, which the parallel compiler's schedule decides (the
    # reviewer's E1). Only an auto-load or ensure-load in the same process
    # first (`ensured`) makes the answer the same.
    test "of the owner's own module by a loaded-now probe refuses unless ensured",
         %{tmp_dir: dir} do
      c =
        dir
        |> ctx(%{"pkg" => ["kernel"], "dep" => ["kernel"]})
        |> with_modules(%{"Elixir.Pkg.Ext" => "pkg", "Elixir.Dep.Ext" => "dep"})

      c = put_in(c.deps["pkg"].children, ["dep"])
      exported = &hex(&1, mfa: "erlang:function_exported/3", caller: frame("Elixir.Pkg", "f", 0))

      assert Probes.decide(exported.("Elixir.Pkg.Ext"), c, "pkg") ==
               {:refuse,
                "compile-time probe of whether a module is loaded: Elixir.Pkg.Ext via " <>
                  "erlang:function_exported/3"}

      assert {:refuse, _} = Probes.decide(exported.("Elixir.Dep.Ext"), c, "dep")

      # An auto-load (the error handler's code:ensure_loaded/1) in the same
      # process first.
      loaded = hex("Elixir.Pkg.Ext") |> at("<0.10.0>", 100)
      c = %{c | ensured: Probes.ensured([{"pkg", loaded}])}

      assert Probes.decide(exported.("Elixir.Pkg.Ext") |> at("<0.10.0>", 200), c, "pkg") ==
               :ignore

      assert {:refuse, _} =
               Probes.decide(exported.("Elixir.Pkg.Ext") |> at("<0.11.0>", 200), c, "pkg")
    end

    # Round-2 ruling 2. A reviewed call site that calls the module directly
    # right before it probes it: plug's `Plug.Builder.init_module_plug/4`
    # runs `plug.init(opts)` and then `function_exported?(plug, :call, 2)`
    # (plug 1.5.0 and later). The module is loaded then on both sides.
    test "a reviewed site's probe right after its direct call is no concern", %{tmp_dir: dir} do
      c =
        dir
        |> ctx(%{"pkg" => ["kernel"], "plug" => ["kernel"]})
        |> with_modules(%{"Elixir.Plug.Builder" => "plug", "Elixir.Plug.Parsers" => "plug"})

      c = put_in(c.deps["pkg"].children, ["plug"])
      c = %{c | hex: {nil, %{"plug" => %{name: "plug", version: "1.20.4", checksum: "x"}}}}
      site = frame("Elixir.Plug.Builder", "init_module_plug", 4)
      probe = hex("Elixir.Plug.Parsers", mfa: "erlang:function_exported/3", caller: site)
      assert Probes.decide(probe, c, "pkg") == :ignore

      # Another function, another arity, an older plug, a Plug.Builder of
      # another application, the module_loaded/1 probe.
      for {event, ctx} <- [
            {put_in(probe["caller"]["function"], "init_fun_plug"), c},
            {put_in(probe["caller"]["arity"], 3), c},
            {probe,
             %{c | hex: {nil, %{"plug" => %{name: "plug", version: "1.4.5", checksum: "x"}}}}},
            # Newer than the newest reviewed release (round 3, R2-4).
            {probe,
             %{c | hex: {nil, %{"plug" => %{name: "plug", version: "1.20.5", checksum: "x"}}}}},
            {probe,
             %{c | hex: {nil, %{"plug" => %{name: "plug", version: "1.21.0", checksum: "x"}}}}},
            {probe, %{c | modules: Map.put(c.modules, "Elixir.Plug.Builder", "pkg")}},
            {%{probe | "mfa" => "erlang:module_loaded/1"}, c}
          ] do
        assert {:refuse, _} = Probes.decide(event, ctx, "pkg"), inspect(event["caller"])
      end
    end

    # The same for phoenix_live_view's tag engine (1.2.0 and later): its
    # tokenizer calls `state.tag_handler.classify_type/1` on every tag, and
    # the compiler of the same template, in the same process, asks
    # `function_exported?(state.tag_handler, :annotate_caller, 3)` for a
    # component call (`maybe_anno_caller/5`). A dependent's ~H component
    # compiles the same either way (phoenix_live_dashboard).
    test "phoenix_live_view's tag engine site is a reviewed one", %{tmp_dir: dir} do
      compiler = "Elixir.Phoenix.LiveView.TagEngine.Compiler"
      engine = "Elixir.Phoenix.LiveView.HTMLEngine"

      c =
        dir
        |> ctx(%{"pkg" => ["kernel"], "phoenix_live_view" => ["kernel"]})
        |> with_modules(%{compiler => "phoenix_live_view", engine => "phoenix_live_view"})

      c = put_in(c.deps["pkg"].children, ["phoenix_live_view"])
      release = &{nil, %{"phoenix_live_view" => %{name: "phoenix_live_view", version: &1}}}
      c = %{c | hex: release.("1.2.15")}

      probe =
        hex(engine,
          mfa: "erlang:function_exported/3",
          caller: frame(compiler, "maybe_anno_caller", 5)
        )

      assert Probes.decide(probe, c, "pkg") == :ignore
      # 1.1 has no such probe; a release older than the reviewed one refuses,
      # and so does one newer than the newest reviewed (round 3, R2-4).
      assert {:refuse, _} = Probes.decide(probe, %{c | hex: release.("1.1.34")}, "pkg")
      assert {:refuse, _} = Probes.decide(probe, %{c | hex: release.("1.2.16")}, "pkg")
      assert {:refuse, _} = Probes.decide(probe, %{c | hex: release.("1.3.0")}, "pkg")
    end

    # Coverage drop 2026-11-22, F2: LiveView's
    # `Phoenix.Component.Declarative.__global__?/3` asks
    # `function_exported?(module, :__global__?, 1)` of the component module
    # it verifies, from that module's own `@after_verify` callback, which
    # Elixir runs in the type checker's process after the beam is written.
    # The answer only picks whether an "undefined attribute" warning prints
    # (phoenix_live_dashboard 0.9.1's NavBarComponent, PageLive and
    # ModalComponent, a real traced build with LiveView 1.2.15).
    test "LiveView's __global__?/3 in the checker's process is a reviewed warnings-only site",
         %{tmp_dir: dir} do
      declarative = "Elixir.Phoenix.Component.Declarative"
      component = "Elixir.Phoenix.LiveDashboard.NavBarComponent"

      c =
        dir
        |> ctx(%{"phoenix_live_dashboard" => ["kernel"], "phoenix_live_view" => ["kernel"]})
        |> with_modules(%{
          declarative => "phoenix_live_view",
          component => "phoenix_live_dashboard"
        })

      c = put_in(c.deps["phoenix_live_dashboard"].children, ["phoenix_live_view"])
      release = &{nil, %{"phoenix_live_view" => %{name: "phoenix_live_view", version: &1}}}
      c = %{c | hex: release.("1.2.15")}
      checker = frame("Elixir.Module.ParallelChecker", "-spawn_checker/7-fun-0-", 7)

      probe =
        component
        |> hex(mfa: "erlang:function_exported/3", caller: frame(declarative, "__global__?", 3))
        |> Map.put("bottom", checker)

      owner = "phoenix_live_dashboard"
      assert Probes.decide(probe, c, owner) == :ignore
      # Elixir 1.19's checker process (`inner_spawn/6`).
      older = put_in(probe["bottom"]["function"], "-inner_spawn/6-fun-0-")
      assert Probes.decide(older, c, owner) == :ignore
      assert Probes.decide(probe, %{c | hex: release.("0.20.0")}, owner) == :ignore

      # Not in the checker's process (a module body calling the public
      # function), no bottom frame, another function or arity, a release
      # outside the reviewed range, the caller's module built by another
      # application, or another probe function: refused as before.
      for {event, ctx} <- [
            {put_in(
               probe["bottom"],
               frame("Elixir.Kernel.ParallelCompiler", "-spawn_workers/8-fun-0-", 8)
             ), c},
            {Map.delete(probe, "bottom"), c},
            {put_in(probe["caller"]["function"], "__global__"), c},
            {put_in(probe["caller"]["arity"], 1), c},
            {probe, %{c | hex: release.("0.19.5")}},
            {probe, %{c | hex: release.("1.2.16")}},
            {probe, %{c | hex: release.("1.3.0")}},
            {probe, %{c | modules: Map.put(c.modules, declarative, owner)}},
            {%{probe | "mfa" => "erlang:module_loaded/1"}, c}
          ] do
        assert {:refuse, _} = Probes.decide(event, ctx, owner),
               inspect(Map.take(event, ["caller", "bottom"]))
      end
    end

    # An installed OTP module on the owner's path is the same: listed, it
    # can be found, but whether it is loaded is the earlier compiles' doing.
    test "an on-path OTP module's loaded-now probe refuses unless ensured first",
         %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel", "mnesia"]})

      exported =
        otp("mnesia", "mnesia",
          mfa: "erlang:function_exported/3",
          caller: frame("Elixir.Pkg", "f", 0),
          arg: %{"by_package" => true}
        )

      # A toolchain function's own check is judged as before.
      toolchain = put_in(exported["arg"]["by_package"], false)
      assert Probes.decide(toolchain, c, "pkg") == :ignore

      assert Probes.decide(exported, c, "pkg") ==
               {:refuse,
                "compile-time probe of whether a module is loaded: mnesia via erlang:function_exported/3"}

      loaded = otp("mnesia", "mnesia") |> at("<0.10.0>", 100)
      c = %{c | ensured: Probes.ensured([{"pkg", loaded}])}
      assert Probes.decide(at(exported, "<0.10.0>", 200), c, "pkg") == :ignore
    end

    # Round-2 ruling 1: a module of a dependency a closure member declares
    # and the build lacks (an optional dependency left out). The client
    # serves a build only to a project whose package closure is the build's,
    # and Mix makes a present optional dependency a child of its declarer:
    # a user who has it never gets this build.
    test "of an absent declared dependency's module is no concern", %{tmp_dir: dir} do
      c =
        dir
        |> ctx(%{"pkg" => ["kernel"], "child" => ["kernel"], "other" => ["kernel"]})
        |> Map.put(:declared, %{
          modules: %{"Elixir.Jason.Encoder" => ["child"], "Elixir.Poison" => ["other"]},
          apps: %{"jason" => ["child"]},
          owners: %{"Elixir.Jason.Encoder" => ["jason"], "Elixir.Poison" => ["poison"]},
          packages: %{"jason" => "jason_app", "poison" => "poison"}
        })

      c = put_in(c.deps["pkg"].children, ["child"])

      # Recorded (round 3, R2-1): the module, absent, the declared packages
      # that define it and how it was asked. The portal refuses it at ingest
      # when another popular package defines it too; client 0.9 checks it.
      absent = %{
        "kind" => "module_absent",
        "module" => "Elixir.Jason.Encoder",
        "declared" => ["jason"],
        "declared_apps" => ["jason_app"],
        "via" => "Code.ensure_loaded?/1"
      }

      assert Probes.decide(hex("Elixir.Jason.Encoder"), c, "pkg") ==
               {:observe, "declared_absent", absent}

      # Declared by a dependency outside the owner's closure: no declaration
      # holds, and the module is recorded as one nothing in the build defines,
      # its declared definer and that one's app named.
      assert {:observe, "probe_inputs", %{"name" => "Elixir.Poison", "definers" => ["poison"]}} =
               Probes.decide(hex("Elixir.Poison"), c, "pkg")

      assert {:observe, "probe_inputs", %{"name" => "Elixir.Jason.Encoder"}} =
               Probes.decide(hex("Elixir.Jason.Encoder"), c, "other")

      # The module is built by a closure application outside the owner's
      # closure (S9, found with F6): whether the owner's compile finds it
      # is Mix's compile order, under Mix.install it does. Refused, even
      # though a declared-absent dependency defines it too.
      built = with_modules(c, Map.put(c.modules, "Elixir.Jason.Encoder", "other"))
      assert {:refuse, _} = Probes.decide(hex("Elixir.Jason.Encoder"), built, "pkg")

      # A loaded-now probe of it: whether it is loaded is no question then
      # either, the module is on no path.
      assert Probes.decide(
               hex("Elixir.Jason.Encoder", mfa: "erlang:function_exported/3"),
               c,
               "pkg"
             ) ==
               {:observe, "declared_absent", absent}

      app = %{
        "channel" => "app_probe",
        "mfa" => "application_controller:get_key/2",
        "arg" => %{"app" => "jason"},
        "caller" => frame("Elixir.Application", "spec", 2)
      }

      assert Probes.decide(app, c, "pkg") == :ignore

      assert {:observe, "probe_inputs", %{"of" => "app", "name" => "poison"}} =
               Probes.decide(put_in(app["arg"]["app"], "poison"), c, "pkg")
    end

    # Coverage drop 2026-11-22, F6: eventstore's
    # `Code.ensure_loaded?(Postgrex.Timestamp)` with postgrex in its
    # closure at a release that does not define it. Every user with this
    # closure has that release (the client matches `deps` by version and
    # checksum), so only a package outside the closure could define the
    # module: recorded as a declared-absent probe is, for the portal's
    # module-index gate. The namespace's package is proved by its verified
    # tarball, which defines the namespace's module and not the probed one.
    test "of an absent module under a closure package's namespace is recorded",
         %{tmp_dir: dir} do
      home = Path.join(dir, "hex")

      {"pg", pg} =
        NccWorker.TracerFixtures.hex_release(home, "pg", ["lib"], %{
          "lib/pg.ex" => "defmodule Pg do\nend\ndefmodule Pg.Extensions.Int do\nend\n"
        })

      c =
        dir
        |> ctx(%{"pkg" => ["kernel"], "pg" => ["kernel"], "other" => ["kernel"]})
        |> with_modules(%{"Elixir.Pg" => "pg", "Elixir.Pg.Extensions.Int" => "pg"})

      c = put_in(c.deps["pkg"].children, ["pg"])
      c = %{c | hex: {home, %{"pg" => pg}}}

      record = %{
        "kind" => "module_absent",
        "module" => "Elixir.Pg.Timestamp",
        "declared" => [],
        "declared_apps" => [],
        "namespace" => "pg",
        "via" => "Code.ensure_loaded?/1"
      }

      assert Probes.decide(hex("Elixir.Pg.Timestamp"), c, "pkg") ==
               {:observe, "declared_absent", record}

      # Deeper: the nearest namespace module the closure builds.
      assert {:observe, "declared_absent", %{"namespace" => "pg"}} =
               Probes.decide(hex("Elixir.Pg.Extensions.Int.Sub"), c, "pkg")

      # The namespace's package outside the prober's closure; a namespace
      # no closure package builds; an Erlang module; a top-level module.
      for {module, owner} <- [
            {"Elixir.Pg.Timestamp", "other"},
            {"Elixir.Other.Timestamp", "pkg"},
            {"pg_timestamp", "pkg"},
            {"Elixir.Timestamp", "pkg"}
          ] do
        assert {:refuse, _} = Probes.decide(hex(module), c, owner), module
      end

      # Built by name alone: the tarball does not define the namespace's
      # module. Or the tarball defines the probed module itself (the build
      # left it out, so another world may not).
      {"pg", bare} =
        NccWorker.TracerFixtures.hex_release(Path.join(dir, "bare"), "pg", ["lib"], %{
          "lib/pg/other.ex" => "defmodule Pg.Other do\nend\n"
        })

      {"pg", both} =
        NccWorker.TracerFixtures.hex_release(Path.join(dir, "both"), "pg", ["lib"], %{
          "lib/pg.ex" =>
            "defmodule Pg do\nend\nif Code.ensure_loaded?(:x) do\n  defmodule Pg.Timestamp do\n  end\nend\n"
        })

      # Built by a closure application outside the prober's closure: Mix's
      # compile order decides whether the prober finds it, Mix.install finds
      # it (the module is no namespace question then).
      built = with_modules(c, Map.put(c.modules, "Elixir.Pg.Timestamp", "other"))
      assert {:refuse, _} = Probes.decide(hex("Elixir.Pg.Timestamp"), built, "pkg")

      for {h, release} <- [
            {Path.join(dir, "bare"), bare},
            {Path.join(dir, "both"), both},
            {nil, pg}
          ] do
        assert {:refuse, _} =
                 Probes.decide(
                   hex("Elixir.Pg.Timestamp"),
                   %{c | hex: {h, %{"pg" => release}}},
                   "pkg"
                 )
      end
    end

    test "the compiler's own lookup is no concern", %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"]})
      lookup = hex("Elixir.Phoenix.HTML.Safe", arg: %{"by_package" => false})
      assert Probes.decide(lookup, c, "pkg") == :ignore

      assert Probes.decide(Map.update!(lookup, "arg", &Map.delete(&1, "by_package")), c, "pkg") ==
               :ignore
    end

    test "from a closure dependency's mix.exs refuses, in the closure or not", %{tmp_dir: dir} do
      c = dir |> ctx(%{"pkg" => ["kernel"]}) |> with_modules(%{"Elixir.Pkg.Other" => "pkg"})
      File.mkdir_p!(Path.join(dir, "deps/pkg"))
      dest = Context.realpath(Path.join(dir, "deps/pkg"))
      File.write!(Path.join(dest, "mix.exs"), "")
      c = put_in(c.deps["pkg"].dest, dest)
      user = %{"file" => Path.join(dest, "mix.exs")}

      for m <- ~w(Elixir.Pkg.Other Elixir.Jason) do
        assert {:refuse, why} = Probes.decide(Map.put(hex(m), "user", user), c, "pkg")

        assert why ==
                 "compile-time probe of a dependency outside the closure: #{m} via Code.ensure_loaded?/1 in mix.exs"
      end
    end

    test "the type checker's, the code server's nested one and @behaviour's are no concern",
         %{tmp_dir: dir} do
      c = ctx(dir, %{"pkg" => ["kernel"]})
      assert Probes.decide(hex("Elixir.Jason", arg: %{"checker" => true}), c, "pkg") == :ignore

      nested =
        hex("Elixir.Jason",
          mfa: "erlang:module_loaded/1",
          caller: frame("code", "ensure_loaded", 1)
        )

      assert Probes.decide(nested, c, "pkg") == :ignore
      assert Probes.decide(hex("Elixir.Jason", arg: %{"attribute" => true}), c, "pkg") == :ignore
    end
  end

  test "a malformed probe is not judged", %{tmp_dir: dir} do
    c = ctx(dir, %{"pkg" => []})
    assert {:unjudged, _} = Probes.decide(%{"channel" => "probe", "arg" => %{}}, c, "pkg")
  end
end
