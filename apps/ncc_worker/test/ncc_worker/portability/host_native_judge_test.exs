defmodule NccWorker.Portability.HostNativeJudgeTest do
  # A host-native build's verdict on hand-built reports (`target: "host"`,
  # `host_native: true`): the firmware target mode plus the package's own
  # priv libraries and R2 on its ebin. The tool's activity on real compiles
  # is `NccWorker.Tracer.FixturesHostNativeTest`.
  use ExUnit.Case, async: true

  alias NccWorker.Portability
  alias NccWorker.Tracer.Report

  @moduletag :tmp_dir

  @libs %{"nif_check" => "ok", "mapped_libs" => ["/usr/lib/libc.so.6"]}
  @host_native [target: "host", host_native: true]

  setup %{tmp_dir: dir} do
    proj = Path.join(dir, "proj")

    for app <- ["dep", "pkg"] do
      File.mkdir_p!(Path.join([proj, "deps", app, "lib"]))
      File.mkdir_p!(Path.join([proj, "_build/host/lib", app, "ebin"]))
      File.write!(Path.join([proj, "deps", app, "lib", app <> ".ex"]), "")
      File.write!(Path.join([proj, "deps", app, "mix.exs"]), "")
    end

    File.mkdir_p!(Path.join([proj, "_build/host/lib/pkg/priv/native"]))
    File.write!(Path.join(proj, "mix.exs"), "")
    %{proj: proj}
  end

  defp dep(proj, app, children) do
    %{
      "app" => app,
      "dest" => Path.join([proj, "deps", app]),
      "build" => Path.join([proj, "_build/host/lib", app]),
      "manager" => "mix",
      "children" => children
    }
  end

  defp window(app, open, close, libs),
    do: %{
      app: app,
      open: open,
      close: close,
      depth_ok: true,
      integrity_ok: true,
      delivered: true,
      libs: libs
    }

  # `pkg_libs`: what is mapped when pkg's window closes and at the end.
  defp report(proj, pkg_libs \\ @libs) do
    %Report{
      start: Map.merge(%{"otp_root" => "/nonexistent-otp"}, @libs),
      closure: %{
        "packages" => ["pkg"],
        "deps" => [dep(proj, "dep", []), dep(proj, "pkg", ["dep"])]
      },
      windows: [window("dep", 10, 20, @libs), window("pkg", 30, 40, pkg_libs)],
      sentinels: [
        %{app: "dep", ts: 11, integrity_ok: true},
        %{app: "pkg", ts: 31, integrity_ok: true}
      ],
      stats: %{"kind" => "stats", "calls" => 10, "unjudged" => 0},
      ending:
        Map.merge(
          %{
            "status" => "ok",
            "depth_ok" => true,
            "final_sentinel" => true,
            "overflow" => false,
            "integrity_ok" => true,
            "delivered" => true
          },
          pkg_libs
        )
    }
  end

  defp judge(proj, report, opts),
    do:
      Portability.judge(proj, "pkg", report, [], [built_check: false, nif_waiver: false] ++ opts)

  defp mapped(proj, path),
    do: %{"nif_check" => "ok", "mapped_libs" => ["/usr/lib/libc.so.6", Path.join(proj, path)]}

  test "a clean trace passes, as a firmware target's does", %{proj: proj} do
    assert %{status: :pass, compile_inputs: [], compile_env: []} =
             judge(proj, report(proj), @host_native)
  end

  test "the package's own priv library may be mapped in its compile", %{proj: proj} do
    libs = mapped(proj, "_build/host/lib/pkg/priv/native/libpkg.so")
    File.write!(Path.join(proj, "_build/host/lib/pkg/priv/native/libpkg.so"), "x")

    assert %{status: :pass, observations: obs} = judge(proj, report(proj, libs), @host_native)
    assert Enum.any?(obs["native_libs"], &String.ends_with?(&1, "/priv/native/libpkg.so"))

    # Not without host_native, and not on the toolchain judge.
    assert %{status: :skip, reason: "compile-time native library load: " <> _} =
             judge(proj, report(proj, libs), target: "host")

    assert %{status: :skip, reason: "compile-time native library load: " <> _} =
             judge(proj, report(proj, libs), [])

    # `host_native:` alone is off.
    assert %{status: :skip} = judge(proj, report(proj, libs), host_native: true)
  end

  test "a library of the package's priv that is gone by the judge refuses", %{proj: proj} do
    # A library loaded and then removed or replaced (`/proc/self/maps` names
    # it `<path> (deleted)`) is none of the files the build publishes.
    nif = "_build/host/lib/pkg/priv/native/libpkg.so"
    File.write!(Path.join(proj, nif), "x")

    for path <- [nif <> " (deleted)", "_build/host/lib/pkg/priv/native/libgone.so"] do
      assert %{status: :skip, reason: "compile-time native library load: " <> lib} =
               judge(proj, report(proj, mapped(proj, path)), @host_native)

      assert lib == Path.join(proj, path)
    end
  end

  test "a library outside the package's priv still refuses", %{proj: proj} do
    for path <- ["_build/host/lib/pkg/ebin/libpkg.so", "_build/host/lib/dep/priv/libdep.so"] do
      libs = mapped(proj, path)

      assert %{status: :skip, reason: "compile-time native library load: " <> _} =
               judge(proj, report(proj, libs), @host_native),
             path
    end
  end

  test "a baked build path in the package's beams refuses", %{proj: proj} do
    source =
      "defmodule HostNativeR2Bake do\n  def f, do: #{inspect(Path.join(proj, "x") <> " y")}\nend\n"

    ebin = Path.join(proj, "_build/host/lib/pkg/ebin")

    for {module, binary} <-
          Code.compile_string(source, Path.join(proj, "deps/pkg/lib/pkg.ex")) do
      File.write!(Path.join(ebin, "#{module}.beam"), binary)
      :code.purge(module)
      :code.delete(module)
    end

    assert %{status: :skip, reason: "bakes the build path: " <> _} =
             judge(proj, report(proj), @host_native)

    # A firmware target's verdict leaves R2 to FirmwareBuildRoot.
    assert %{status: :pass} = judge(proj, report(proj), target: "host")
  end

  describe "the libraries the package's own priv library needs (judge revision 25)" do
    # zlib from the compatibility app's ELF fixtures (soname libz.so.1,
    # needing libc.so.6), its `.dynstr` names rewritten in place (same
    # length): the package's NIF needs `libq.so.1`, which needs `libr.so.1`,
    # as tokenizers' NIF needs glibc's libdl.so.2 and libpthread.so.0.
    @zlib Path.expand("../../../../compatibility/test/fixtures/elf/libz_aarch64.so.1", __DIR__)

    defp patched(path, pairs) do
      bytes =
        Enum.reduce(pairs, File.read!(@zlib), fn {from, to}, bin ->
          :binary.replace(bin, from, to, [:global])
        end)

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
      path
    end

    setup %{proj: proj, tmp_dir: dir} do
      sys = Path.join(dir, "sys")
      libc = Path.join(sys, "libc.so.6")
      File.mkdir_p!(sys)
      File.write!(libc, "")

      nif =
        patched(Path.join(proj, "_build/host/lib/pkg/priv/native/libpkg.so"), [
          {"libc.so.6", "libq.so.1"}
        ])

      # Mapped by the file name the loader opened, not the soname.
      libq =
        patched(Path.join(sys, "libq-1.2.so"), [
          {"libz.so.1", "libq.so.1"},
          {"libc.so.6", "libr.so.1"}
        ])

      libr = patched(Path.join(sys, "libr.so.1"), [{"libz.so.1", "libr.so.1"}])
      unneeded = patched(Path.join(sys, "libu.so.1"), [{"libz.so.1", "libu.so.1"}])
      start = %{"nif_check" => "ok", "mapped_libs" => [libc]}
      %{sys: sys, start: start, nif: nif, libq: libq, libr: libr, unneeded: unneeded}
    end

    defp snap(start, extra), do: %{start | "mapped_libs" => start["mapped_libs"] ++ extra}

    # `dep_libs` at dep's window close, `pkg_libs` at pkg's and at the end.
    defp libs_report(ctx, dep_libs, pkg_libs) do
      r = report(ctx.proj, snap(ctx.start, pkg_libs))
      [dep, pkg] = r.windows

      %{
        r
        | start: Map.merge(r.start, ctx.start),
          windows: [%{dep | libs: snap(ctx.start, dep_libs)}, pkg]
      }
    end

    defp ljudge(ctx, dep_libs, pkg_libs, opts \\ @host_native),
      do: judge(ctx.proj, libs_report(ctx, dep_libs, pkg_libs), opts)

    @load "compile-time native library load: "

    test "mapped with the package's NIF, from the C library's dir: let through", ctx do
      assert %{status: :pass, observations: obs} =
               ljudge(ctx, [], [ctx.nif, ctx.libq, ctx.libr])

      assert Enum.sort(obs["native_libs"]) == Enum.sort([ctx.nif, ctx.libq, ctx.libr])

      # Not without host_native, nor on the toolchain judge: the NIF itself refuses.
      for opts <- [[target: "host"], []] do
        assert %{status: :skip, reason: @load <> _} =
                 ljudge(ctx, [], [ctx.nif, ctx.libq, ctx.libr], opts)
      end
    end

    test "every other new library keeps its refusal", ctx do
      elsewhere = patched(Path.join(ctx.tmp_dir, "other/libq.so.1"), [{"libz.so.1", "libq.so.1"}])

      for {dep_libs, pkg_libs, refused} <- [
            # Not named by the NIF's DT_NEEDED (nor through what it names).
            {[], [ctx.nif, ctx.libq, ctx.libr, ctx.unneeded], ctx.unneeded},
            # Named, but not with the NIF: mapped in an earlier window.
            {[ctx.libq], [ctx.nif, ctx.libr], ctx.libq},
            # Named, without the NIF that names it.
            {[], [ctx.libq], ctx.libq},
            # Named, but not from the C library's dir.
            {[], [ctx.nif, elsewhere], elsewhere}
          ] do
        assert %{status: :skip, reason: reason} = ljudge(ctx, dep_libs, pkg_libs)
        assert reason =~ @load, reason
        assert reason =~ refused, reason
      end
    end

    test "let through only in the snapshot it shows with the NIF in", ctx do
      # libq mapped in dep's window, gone by pkg's, mapped again at the end
      # with the NIF that names it: dep's window keeps its refusal.
      report = libs_report(ctx, [ctx.libq], [])
      ending = Map.merge(report.ending, snap(ctx.start, [ctx.nif, ctx.libq, ctx.libr]))

      assert %{status: :skip, reason: reason} =
               judge(ctx.proj, %{report | ending: ending}, @host_native)

      assert reason =~ @load <> ctx.libq, reason
    end
  end

  describe "rustler_precompiled's normal path (tokenizers 0.5.2)" do
    # The two events a host-native build of tokenizers 0.5.2 was refused for
    # (production canary, judge revision 23), as the tracer wrote them. The
    # tool's macro holds `use Rustler, only_rustler_opts` in the branch its
    # `__using__/2` takes only for a force build, whenever Rustler is loaded
    # (the optional dependency the run adds), so the expander calls
    # Rustler's macro while it expands that quote. Its download unpacks the
    # archive with `:erl_tar.extract({:binary, tar_gz}, [:compressed, ...])`,
    # which opens OTP's in-memory ram_file driver.
    @tools ["rustler_precompiled", "rustler"]
    @modules %{
      "rustler_precompiled" => ["Elixir.RustlerPrecompiled", "Elixir.RustlerPrecompiled.Config"],
      "rustler" => ["Elixir.Rustler", "Elixir.Rustler.Compiler"]
    }
    @expand %{
      "module" => "elixir_dispatch",
      "function" => "expand_macro_fun",
      "arity" => 7,
      "line" => 263,
      "file" => "src/elixir_dispatch.erl"
    }
    @body %{
      "module" => "elixir_compiler_66",
      "function" => "__MODULE__",
      "arity" => 1,
      "line" => 8,
      "file" => "lib/pkg/native.ex"
    }
    @ll_open %{
      "module" => "ram_file",
      "function" => "ll_open",
      "arity" => 3,
      "line" => 346,
      "file" => "ram_file.erl"
    }
    @download %{
      "module" => "Elixir.RustlerPrecompiled",
      "function" => "download_or_reuse_nif_file",
      "arity" => 2,
      "line" => 790,
      "file" => "lib/rustler_precompiled.ex"
    }
    @ram_port "{spawn,\"ram_file_drv\"}"

    setup %{proj: proj, tmp_dir: dir} do
      home = Path.join(dir, "hex")

      releases =
        for app <- @tools, into: %{} do
          contents = %{"lib/#{app}.ex" => "", "mix.exs" => ""}

          for {path, body} <- contents do
            File.mkdir_p!(Path.dirname(Path.join([proj, "deps", app, path])))
            File.write!(Path.join([proj, "deps", app, path]), body)
          end

          ebin = Path.join([proj, "_build/host/lib", app, "ebin"])
          File.mkdir_p!(ebin)
          modules = Enum.map_join(@modules[app], ",", &"'#{&1}'")

          File.write!(
            Path.join(ebin, app <> ".app"),
            "{application,#{app},[{modules,[#{modules}]}]}.\n"
          )

          NccWorker.TracerFixtures.hex_release(home, app, Map.keys(contents), contents)
        end

      %{hex: [releases: releases, hex_home: home]}
    end

    defp tools_report(proj, events) do
      base = report(proj)

      %{
        base
        | events: events,
          closure: %{
            "packages" => ["pkg"],
            "deps" => [
              dep(proj, "rustler", []),
              dep(proj, "rustler_precompiled", []),
              dep(proj, "dep", []),
              dep(proj, "pkg", ["dep", "rustler", "rustler_precompiled"])
            ]
          },
          windows:
            [window("rustler", 1, 4, @libs), window("rustler_precompiled", 5, 9, @libs)] ++
              base.windows,
          sentinels:
            [
              %{app: "rustler", ts: 2, integrity_ok: true},
              %{app: "rustler_precompiled", ts: 6, integrity_ok: true}
            ] ++ base.sentinels
      }
    end

    defp tjudge(ctx, events, opts) do
      Portability.judge(
        ctx.proj,
        "pkg",
        tools_report(ctx.proj, events),
        @tools,
        [built_check: false, nif_waiver: false] ++ ctx.hex ++ opts
      )
    end

    # The expander calling a macro: no frame but the compiler's.
    defp expansion(ts, mfa, module, pid \\ "<0.463.0>"),
      do: %{
        "ts" => ts,
        "pid" => pid,
        "channel" => "native_closure",
        "mfa" => mfa,
        "arg" => %{"module" => module},
        "extent" => "dispatcher",
        "first" => @expand,
        "caller" => @expand,
        "user" => nil,
        "first_kind" => "glue",
        "caller_kind" => "toolchain"
      }

    defp tool_macro(ts, pid \\ "<0.463.0>"),
      do: expansion(ts, "RustlerPrecompiled.MACRO-__using__/2", "Elixir.RustlerPrecompiled", pid)

    defp rustler_macro(ts, pid \\ "<0.463.0>"),
      do: expansion(ts, "Rustler.MACRO-__using__/2", "Elixir.Rustler", pid)

    # The package's module body calling into a tool's module.
    defp body_call(ts, mfa, module),
      do: %{
        "ts" => ts,
        "pid" => "<0.463.0>",
        "channel" => "native_closure",
        "mfa" => mfa,
        "arg" => %{"module" => module},
        "extent" => "frame",
        "first" => @body,
        "caller" => @body,
        "user" => @body,
        "first_kind" => "user",
        "caller_kind" => "user"
      }

    defp tool_fun(ts),
      do: body_call(ts, "RustlerPrecompiled.__using__/2", "Elixir.RustlerPrecompiled")

    defp port(ts, port, first, user),
      do: %{
        "ts" => ts,
        "pid" => "<0.463.0>",
        "channel" => "programs",
        "mfa" => "erlang:open_port/2",
        "arg" => %{"port" => port},
        "extent" => "frame",
        "first" => first,
        "caller" => first,
        "user" => user,
        "first_kind" => "toolchain",
        "caller_kind" => "toolchain"
      }

    defp ram_port(ts), do: port(ts, @ram_port, @ll_open, @download)

    @macro_refusal "calls natively built dependency at compile time: Rustler.MACRO-__using__/2"
    @port_refusal "compile-time host read: erlang:open_port/2 via ram_file:ll_open/3 in " <>
                    "RustlerPrecompiled.download_or_reuse_nif_file/2 (lib/rustler_precompiled.ex:790)"

    test "the tokenizers trace passes in a host-native build only", ctx do
      events = [tool_macro(32), rustler_macro(33), tool_fun(34), ram_port(35)]

      assert %{status: :pass, observations: obs} = tjudge(ctx, events, @host_native)
      assert obs["refusals"] == []

      assert Enum.any?(obs["native_build"], &(&1["mfa"] == "Rustler.MACRO-__using__/2")),
             inspect(obs["native_build"])

      assert Enum.any?(obs["native_build"], &(&1["mfa"] == "erlang:open_port/2"))

      # A firmware target's trace and the toolchain judge refuse both.
      for opts <- [[target: "host"], []] do
        assert %{status: :skip, observations: %{"refusals" => refusals}} =
                 tjudge(ctx, events, opts)

        reasons = Enum.map(refusals, & &1["reason"])
        assert @macro_refusal in reasons, inspect(opts)
      end

      assert %{status: :skip, reason: @port_refusal} = tjudge(ctx, [ram_port(35)], target: "host")
    end

    test "each refusal on its own, as the canary recorded them", ctx do
      assert %{status: :skip, observations: %{"refusals" => refusals}} =
               tjudge(ctx, [tool_macro(32), rustler_macro(33)], target: "host")

      assert %{"owner" => "pkg", "reason" => @macro_refusal} in refusals

      assert %{status: :pass} = tjudge(ctx, [tool_macro(32), rustler_macro(33)], @host_native)
      assert %{status: :pass} = tjudge(ctx, [ram_port(35)], @host_native)
    end

    test "a use Rustler the tool's quote did not hold keeps its refusal", ctx do
      for events <- [
            # The package's own `use Rustler`, with no tool macro before it.
            [rustler_macro(33)],
            [rustler_macro(32), tool_macro(33)],
            # One expansion per tool macro: a second one is the package's.
            [tool_macro(32), rustler_macro(33), rustler_macro(34)],
            # Another process's macro.
            [tool_macro(32, "<0.9.0>"), rustler_macro(33)]
          ] do
        assert %{status: :skip, reason: @macro_refusal} = tjudge(ctx, events, @host_native),
               inspect(Enum.map(events, &{&1["mfa"], &1["pid"]}))
      end
    end

    test "running Rustler's code keeps its refusal: a force build, a package frame", ctx do
      # The force-build branch runs `Rustler.Compiler.compile_crate/3` from
      # the module body, and `@before_compile Rustler` calls its macro.
      compile = body_call(36, "Rustler.Compiler.compile_crate/3", "Elixir.Rustler.Compiler")

      # `@before_compile` reaches the macro through the expander too.
      before = expansion(37, "Rustler.MACRO-__before_compile__/2", "Elixir.Rustler")

      for {extra, reason} <- [
            {compile,
             "calls natively built dependency at compile time: " <>
               "Rustler.Compiler.compile_crate/3"},
            {before,
             "calls natively built dependency at compile time: " <>
               "Rustler.MACRO-__before_compile__/2"}
          ] do
        events = [tool_macro(32), rustler_macro(33), tool_fun(34), extra]
        assert %{status: :skip, reason: ^reason} = tjudge(ctx, events, @host_native)
      end

      # Rustler's macro called with a package frame on the stack (a macro of
      # the package's own expanding it), and from another caller.
      framed = %{rustler_macro(33) | "extent" => "frame", "user" => @body}
      direct = %{rustler_macro(33) | "caller" => @body, "first" => @body}

      for event <- [framed, direct] do
        assert %{status: :skip, reason: @macro_refusal} =
                 tjudge(ctx, [tool_macro(32), event], @host_native)
      end

      # Another native dependency's macro is no Rustler expansion.
      other = expansion(33, "RustlerPrecompiled.Config.MACRO-__using__/2", "x")

      assert %{status: :skip} =
               tjudge(ctx, [tool_macro(32), %{other | "arg" => %{}}], @host_native)
    end

    # rustler_precompiled's `variant_suffix/2` runs each variant fun of the
    # package's (`fn -> ... end`) from a callback that tail-calls it, under
    # `Enum.find/3`: a variant fun that tail-calls a read leaves the tool's
    # frame first, though the read is the package's and picks the NIF.
    @variant %{
      "module" => "Elixir.RustlerPrecompiled",
      "function" => "variant_suffix",
      "arity" => 2,
      "line" => 725,
      "file" => "lib/rustler_precompiled.ex"
    }
    @find %{
      "module" => "Elixir.Enum",
      "function" => "find_list",
      "arity" => 3,
      "line" => 4300,
      "file" => "lib/enum.ex"
    }

    defp tool_read(ts, channel, mfa, arg, user),
      do: %{
        "ts" => ts,
        "pid" => "<0.463.0>",
        "channel" => channel,
        "mfa" => mfa,
        "arg" => arg,
        "extent" => "frame",
        "first" => @find,
        "caller" => @find,
        "user" => user,
        "first_kind" => "glue",
        "caller_kind" => "toolchain"
      }

    test "a variant fun's tail-called read is the package's, not the tool's", ctx do
      env = tool_read(35, "env", "os:getenv/1", %{"name" => "FX_LEGACY"}, @variant)
      path = "/sys/devices/system/cpu/fx_legacy"
      file = tool_read(35, "file_read", "file:read_file_info/2", %{"path" => path}, @variant)
      callback = %{@variant | "function" => "-variant_suffix/2-fun-0-"}

      # The env read is a compile input, as the package's own is.
      for user <- [@variant, callback] do
        assert %{status: :pass, compile_inputs: inputs} =
                 tjudge(ctx, [tool_fun(34), %{env | "user" => user}], @host_native)

        assert Enum.any?(inputs, &match?(%{"kind" => "env", "name" => "FX_LEGACY"}, &1)),
               inspect(inputs)
      end

      # A host read refuses.
      assert %{status: :skip, reason: "compile-time host read: " <> reason} =
               tjudge(ctx, [tool_fun(34), file], @host_native)

      assert reason =~ path

      # The same reads from the tool's own code (its download) stay set apart.
      for event <- [env, file] do
        assert %{status: :pass, compile_inputs: []} =
                 tjudge(ctx, [tool_fun(34), %{event | "user" => @download}], @host_native)
      end
    end

    test "the tool's TARGET_* reads, which override the triple, are inputs", ctx do
      # `maybe_override_with_env_vars/2` reads them from a fun of its own;
      # a client that sets one would download another target's NIF.
      override = %{
        @variant
        | "function" => "-maybe_override_with_env_vars/2-fun-0-",
          "line" => 596
      }

      for name <- ~w(TARGET_ARCH TARGET_VENDOR TARGET_OS TARGET_ABI) do
        read = tool_read(35, "env", "os:getenv/1", %{"name" => name}, override)

        assert %{status: :pass, compile_inputs: inputs} =
                 tjudge(ctx, [tool_fun(34), read], @host_native)

        assert Enum.any?(inputs, &match?(%{"kind" => "env", "name" => ^name}, &1)),
               inspect({name, inputs})
      end

      # Its download's env reads (proxies, the IP family) stay set apart.
      for name <- ~w(HTTPS_PROXY RUSTLER_PRECOMPILED_IPFAMILY) do
        read = tool_read(35, "env", "os:getenv/1", %{"name" => name}, @download)

        assert %{status: :pass, compile_inputs: []} =
                 tjudge(ctx, [tool_fun(34), read], @host_native)
      end
    end

    test "in a dependency's window both keep their decision: the dependency is tainted", ctx do
      # `dep`'s window is 10..20 (pkg depends on it).
      for {events, taint} <- [
            {[tool_macro(12), rustler_macro(13)], @macro_refusal},
            {[ram_port(14)], @port_refusal}
          ] do
        assert %{status: :skip, reason: reason, observations: obs} =
                 tjudge(ctx, events, @host_native)

        assert reason =~ taint

        assert obs["taint"] == %{"dep" => taint}
      end
    end

    test "the ram_file driver is set apart only in the tool's download frame", ctx do
      certs = %{@download | "function" => "otp_cacerts", "arity" => 0, "line" => 1086}
      security = "{spawn_executable,\"/usr/bin/security\"}"

      package = %{
        "module" => "Elixir.Pkg.Native",
        "function" => "unpack",
        "arity" => 0,
        "line" => 3,
        "file" => "lib/pkg/native.ex"
      }

      for event <- [
            # The same driver from another of the tool's functions.
            port(35, @ram_port, @ll_open, certs),
            # Another port from the download frame.
            port(35, security, @ll_open, @download),
            port(35, "{spawn,\"tar xzf -\"}", @ll_open, @download),
            # Not opened by OTP's ram_file.
            port(35, @ram_port, @download, @download),
            %{ram_port(35) | "first_kind" => "user"},
            # The package's own unpack.
            port(35, @ram_port, @ll_open, package)
          ] do
        assert %{status: :skip, reason: "compile-time host read: erlang:open_port/2" <> _} =
                 tjudge(ctx, [event], @host_native),
               inspect({event["arg"], event["first"], event["user"]})
      end
    end
  end

  test "the tools a host-native build sets apart" do
    assert Portability.native_tools() == ["elixir_make"]
    assert Portability.host_native_tools() == ["rustler_precompiled"]
  end
end
