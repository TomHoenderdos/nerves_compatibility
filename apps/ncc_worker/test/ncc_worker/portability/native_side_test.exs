defmodule NccWorker.Portability.NativeSideTest do
  # `native_side: true` on hand-built reports: in a closure dependency's
  # window, the reviewed native build tool's own activity (elixir_make and
  # cc_precompiler deciding the dependency's NIF) is set apart from the
  # dependency's beams, which a dependent compiles against, as a firmware
  # target's trace already sets it apart. The dependency's beams must then
  # be shown to be its sources' alone. The same tool on real compiles is
  # `NccWorker.Tracer.FixturesNativeSideTest`.
  use ExUnit.Case, async: true

  alias NccWorker.Portability
  alias NccWorker.Tracer.Report

  @moduletag :tmp_dir

  @libs %{"nif_check" => "ok", "mapped_libs" => ["/usr/lib/libc.so.6"]}
  @native ["dep", "elixir_make"]
  @on [native_side: true]

  # The reviewed tools as the lock resolves them (review M3): the Hex
  # package of the app's own name, in a reviewed version.
  @tools %{
    "elixir_make" => %{
      name: "elixir_make",
      version: "0.10.1",
      checksum: String.duplicate("a", 64)
    },
    "cc_precompiler" => %{
      name: "cc_precompiler",
      version: "0.1.11",
      checksum: String.duplicate("b", 64)
    }
  }

  @tool_modules ~w(Elixir.Mix.Tasks.Compile.ElixirMake Elixir.ElixirMake.Compiler
                   Elixir.ElixirMake.Artefact)

  # deps/<app> and _build/host/lib/<app>/ebin for elixir_make (the tool, its
  # modules listed in its .app), dep (natively built with it: a verified Hex
  # release whose files are exactly deps/dep's, and one beam compiled from
  # its own source) and pkg, which depends on dep.
  setup %{tmp_dir: dir} do
    proj = Path.join(dir, "proj")

    for app <- ["elixir_make", "dep", "pkg"] do
      File.mkdir_p!(Path.join([proj, "deps", app, "lib"]))
      File.mkdir_p!(Path.join([proj, "_build/host/lib", app, "ebin"]))
      File.write!(Path.join([proj, "deps", app, "mix.exs"]), "")
    end

    File.write!(Path.join([proj, "deps/elixir_make/lib/elixir_make.ex"]), "")
    File.write!(Path.join([proj, "deps/pkg/lib/pkg.ex"]), "")
    File.write!(Path.join(proj, "mix.exs"), "")

    modules = Enum.map_join(@tool_modules, ",", &"'#{&1}'")

    File.write!(
      Path.join([proj, "_build/host/lib/elixir_make/ebin/elixir_make.app"]),
      "{application,elixir_make,[{modules,[#{modules}]}]}.\n"
    )

    module = "NativeSideDep#{System.unique_integer([:positive])}"
    source = "defmodule #{module} do\n  def f(x), do: x + 1\nend\n"
    File.write!(Path.join([proj, "deps/dep/lib/dep.ex"]), source)
    write_beam(proj, "dep", source)

    home = Path.join(dir, "hex")

    {"dep", release} =
      NccWorker.TracerFixtures.hex_release(home, "dep", ["lib", "mix.exs"], %{
        "lib/dep.ex" => source,
        "mix.exs" => ""
      })

    beam = Path.join(proj, "_build/host/lib/dep/ebin/Elixir.#{module}.beam")
    releases = Map.merge(@tools, %{"dep" => release})
    opts = [releases: releases, hex_home: home, nif_waiver: false]
    %{proj: proj, home: home, beam: beam, opts: opts, source: source, releases: releases}
  end

  defp write_beam(proj, app, source, file \\ nil) do
    ebin = Path.join([proj, "_build/host/lib", app, "ebin"])
    file = file || Path.join([proj, "deps", app, "lib", app <> ".ex"])

    for {module, binary} <- Code.compile_string(source, file) do
      File.write!(Path.join(ebin, "#{module}.beam"), binary)
      :code.purge(module)
      :code.delete(module)
    end
  end

  defp dep(proj, app, children, manager \\ "mix") do
    %{
      "app" => app,
      "dest" => Path.join([proj, "deps", app]),
      "build" => Path.join([proj, "_build/host/lib", app]),
      "manager" => manager,
      "children" => children
    }
  end

  defp window(app, open, close, libs \\ @libs),
    do: %{
      app: app,
      open: open,
      close: close,
      depth_ok: true,
      integrity_ok: true,
      delivered: true,
      libs: libs
    }

  # `dep_libs`: what is mapped when dep's window closes (and from then on).
  defp report(proj, events, overrides \\ %{}, dep_libs \\ @libs) do
    struct!(
      %Report{
        start: Map.merge(%{"otp_root" => "/nonexistent-otp"}, @libs),
        closure: %{
          "packages" => ["pkg"],
          "deps" => [
            dep(proj, "elixir_make", []),
            dep(proj, "dep", ["elixir_make"]),
            dep(proj, "pkg", ["dep"])
          ]
        },
        windows: [
          window("elixir_make", 5, 9),
          window("dep", 10, 20, dep_libs),
          window("pkg", 30, 40, dep_libs)
        ],
        sentinels: [
          %{app: "elixir_make", ts: 6, integrity_ok: true, pid: "<0.95.0>"},
          %{app: "dep", ts: 11, integrity_ok: true, pid: "<0.95.0>"},
          %{app: "pkg", ts: 31, integrity_ok: true, pid: "<0.95.0>"}
        ],
        stats: %{"kind" => "stats", "calls" => 10, "unjudged" => 0},
        events: events,
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
            dep_libs
          )
      },
      overrides
    )
  end

  defp judge(proj, report, opts),
    do: Portability.judge(proj, "pkg", report, @native, Keyword.put(opts, :built_check, false))

  defp frame(module, fun, file),
    do: %{"module" => module, "function" => fun, "arity" => 1, "file" => file, "line" => 2}

  # An event of elixir_make's own code: its compile task's frame on top.
  defp tool(ts, mfa, channel, arg, module \\ "Elixir.Mix.Tasks.Compile.ElixirMake") do
    user = frame(module, "run", "lib/mix/tasks/compile.elixir_make.ex")

    %{
      "ts" => ts,
      "channel" => channel,
      "mfa" => mfa,
      "arg" => arg,
      "extent" => "frame",
      "first" => %{"module" => module},
      "user" => user
    }
  end

  # The package's own code (`file`, in the window it falls in).
  defp own(ts, mfa, channel, arg, file) do
    %{
      "ts" => ts,
      "channel" => channel,
      "mfa" => mfa,
      "arg" => arg,
      "extent" => "frame",
      "first" => %{"module" => "Elixir.X"},
      "user" => frame("Elixir.X", "__MODULE__", file)
    }
  end

  defp nif_version(ts),
    do: tool(ts, "erlang:system_info/1", "os_identity", %{"key" => "nif_version"})

  defp make(ts),
    do:
      tool(
        ts,
        "erlang:open_port/2",
        "programs",
        %{"port" => ~s({spawn_executable,"make"})},
        "Elixir.ElixirMake.Compiler"
      )

  defp download(ts),
    do: tool(ts, "httpc:request/4", "network", %{}, "Elixir.ElixirMake.Artefact")

  defp beam_read(ts, path),
    do: own(ts, "prim_file:read_file/1", "file_read", %{"path" => path}, "lib/pkg.ex")

  defp tool_run, do: [nif_version(12), make(13), download(14)]

  test "without the option, the tool's reads taint the dependency as before", ctx do
    for event <- [nif_version(12), make(13), download(14)] do
      assert %{status: :skip, reason: "closure dependency observed the host: dep (" <> _} =
               judge(ctx.proj, report(ctx.proj, [event]), ctx.opts)
    end

    assert %{observations: %{"trace_stats" => %{"native_side" => "off"}}} =
             judge(ctx.proj, report(ctx.proj, tool_run()), ctx.opts)
  end

  test "the tool's own activity in a dependency's window is set apart", ctx do
    v = judge(ctx.proj, report(ctx.proj, tool_run()), ctx.opts ++ @on)
    assert %{status: :pass, reason: nil, observations: obs} = v, inspect(v.observations)
    assert length(obs["native_build"]) == 3
    assert Enum.all?(obs["native_build"], &(&1["owner"] == "dep"))
    assert obs["trace_stats"]["native_side"] == "on"
    assert obs["taint"] == %{}

    # Each one alone, and its own compile task run by Mix.
    for event <- tool_run() do
      assert %{status: :pass} = judge(ctx.proj, report(ctx.proj, [event]), ctx.opts ++ @on)
    end

    run =
      12
      |> tool("Mix.Tasks.Compile.ElixirMake.run/1", "native_closure", %{
        "module" => "Elixir.Mix.Tasks.Compile.ElixirMake"
      })
      |> Map.merge(%{
        "user" => nil,
        "extent" => "dispatcher",
        "caller" => %{"module" => "Elixir.Mix.Task", "function" => "-run_task/5-fun-3-"}
      })

    assert %{status: :pass} = judge(ctx.proj, report(ctx.proj, [run]), ctx.opts ++ @on)
  end

  test "a dependent reads the dependency's beams once its native side is set apart", ctx do
    events = tool_run() ++ [beam_read(35, ctx.beam)]

    assert %{status: :skip, reason: "compile-time host read: prim_file:read_file/1 " <> _} =
             judge(ctx.proj, report(ctx.proj, [beam_read(35, ctx.beam)]), [])

    assert %{status: :pass, observations: obs} =
             judge(ctx.proj, report(ctx.proj, events), ctx.opts ++ @on)

    assert [%{"owner" => "pkg", "app" => "dep"} = item] = obs["native_beam_reads"]
    refute Map.has_key?(item, "refusal")

    # Any other file in its ebin may be one the native build wrote.
    other = Path.join(ctx.proj, "_build/host/lib/dep/ebin/dep.app")
    File.write!(other, "{application,dep,[]}.\n")

    assert %{status: :skip, reason: "compile-time host read: prim_file:read_file/1 " <> _} =
             judge(
               ctx.proj,
               report(ctx.proj, tool_run() ++ [beam_read(35, other)]),
               ctx.opts ++ @on
             )
  end

  test "OTP's own libraries a download maps do not stop a dependent's beam read", ctx do
    crypto = "/nonexistent-otp/lib/crypto-5.5/priv/lib/crypto.so"
    libs = %{"nif_check" => "ok", "mapped_libs" => ["/usr/lib/libc.so.6", crypto]}
    r = report(ctx.proj, tool_run() ++ [beam_read(35, ctx.beam)], %{}, libs)
    assert %{status: :pass} = judge(ctx.proj, r, ctx.opts ++ @on)
  end

  test "the dependency's own code is judged as before", ctx do
    taint =
      own(
        15,
        "erlang:system_info/1",
        "os_identity",
        %{"key" => "system_architecture"},
        "lib/dep.ex"
      )

    assert %{status: :skip, reason: "closure dependency observed the host: dep (" <> inner} =
             judge(ctx.proj, report(ctx.proj, tool_run() ++ [taint]), ctx.opts ++ @on)

    assert inner =~ "system_architecture"
  end

  test "the tool writing the env or the app config, or touching the trace, refuses", ctx do
    for {channel, mfa} <- [
          {"env_write", "os:putenv/2"},
          {"config_write", "application:set_env/3"}
        ] do
      event = tool(15, mfa, channel, %{"name" => "CC"})

      assert %{status: :skip, reason: reason} =
               judge(ctx.proj, report(ctx.proj, tool_run() ++ [event]), ctx.opts ++ @on)

      assert reason ==
               "closure dependency observed the host: dep (compile-time write from the " <>
                 "native build tool's frame: #{mfa})"
    end

    integrity = tool(15, "erlang:trace/3", "integrity", %{})

    assert %{status: :skip, reason: "closure dependency observed the host: dep (" <> inner} =
             judge(ctx.proj, report(ctx.proj, tool_run() ++ [integrity]), ctx.opts ++ @on)

    assert inner =~ "compile-time tracing or system flag"
  end

  test "the tool in the package's own window keeps its refusal", ctx do
    in_pkg = for e <- tool_run(), do: %{e | "ts" => e["ts"] + 20}
    r = report(ctx.proj, in_pkg)

    r = %{
      r
      | closure: %{
          r.closure
          | "deps" => [
              dep(ctx.proj, "elixir_make", []),
              dep(ctx.proj, "dep", []),
              dep(ctx.proj, "pkg", ["dep", "elixir_make"])
            ]
        }
    }

    assert %{status: :skip, reason: "compile-time host read: erlang:system_info/1" <> _} =
             judge(ctx.proj, r, ctx.opts ++ @on)
  end

  test "its own NIF mapped while it compiled taints the dependency", ctx do
    nif = Path.join(ctx.proj, "_build/host/lib/dep/priv/dep_nif.so")
    File.mkdir_p!(Path.dirname(nif))
    File.write!(nif, "")
    libs = %{"nif_check" => "ok", "mapped_libs" => ["/usr/lib/libc.so.6", nif]}
    r = report(ctx.proj, tool_run(), %{}, libs)

    assert %{status: :skip, reason: reason} = judge(ctx.proj, r, ctx.opts ++ @on)

    assert reason ==
             "closure dependency observed the host: dep (compile-time native library load: #{nif})"
  end

  test "a source tree that is not its verified tarball's taints the dependency", ctx do
    File.write!(Path.join(ctx.proj, "deps/dep/lib/generated.ex"), "")

    assert %{status: :skip, reason: reason} =
             judge(ctx.proj, report(ctx.proj, tool_run()), ctx.opts ++ @on)

    assert reason ==
             "closure dependency observed the host: dep (native build not set apart: " <>
               "source tree is not its verified tarball's)"

    # No verified tarball at all.
    assert %{
             status: :skip,
             reason: "closure dependency observed the host: dep (native build" <> _
           } =
             judge(
               ctx.proj,
               report(ctx.proj, tool_run()),
               Keyword.put(ctx.opts, :releases, Map.delete(ctx.releases, "dep")) ++ @on
             )
  end

  test "a beam not compiled from the dependency's own sources taints it", ctx do
    elsewhere = Path.join(ctx.proj, "_build/host/lib/dep/obj/gen.ex")
    File.mkdir_p!(Path.dirname(elsewhere))
    File.write!(elsewhere, "")
    module = "NativeSideGen#{System.unique_integer([:positive])}"
    write_beam(ctx.proj, "dep", "defmodule #{module} do\nend\n", elsewhere)

    assert %{status: :skip, reason: reason} =
             judge(ctx.proj, report(ctx.proj, tool_run()), ctx.opts ++ @on)

    assert reason ==
             "closure dependency observed the host: dep (native build not set apart: " <>
               "beam not compiled from its own sources: Elixir.#{module}.beam)"
  end

  test "a checksum file that is not a literal map taints the dependency", ctx do
    checksum = ~s|%{"dep-nif.tar.gz" => "sha256:" <> String.duplicate("0", 64)}\n|
    File.write!(Path.join(ctx.proj, "deps/dep/checksum.exs"), checksum)

    {"dep", release} =
      NccWorker.TracerFixtures.hex_release(ctx.home, "dep", ["lib", "mix.exs", "checksum.exs"], %{
        "lib/dep.ex" => ctx.source,
        "mix.exs" => "",
        "checksum.exs" => checksum
      })

    opts = Keyword.put(ctx.opts, :releases, Map.put(ctx.releases, "dep", release)) ++ @on

    assert %{status: :skip, reason: reason} = judge(ctx.proj, report(ctx.proj, tool_run()), opts)

    assert reason ==
             "closure dependency observed the host: dep (native build not set apart: " <>
               "checksum file is not a literal map: checksum.exs)"
  end

  test "a literal checksum file is fine", ctx do
    checksum = ~s|%{"dep-nif.tar.gz" => "sha256:#{String.duplicate("0", 64)}"}\n|
    File.write!(Path.join(ctx.proj, "deps/dep/checksum.exs"), checksum)

    {"dep", release} =
      NccWorker.TracerFixtures.hex_release(ctx.home, "dep", ["lib", "mix.exs", "checksum.exs"], %{
        "lib/dep.ex" => ctx.source,
        "mix.exs" => "",
        "checksum.exs" => checksum
      })

    opts = Keyword.put(ctx.opts, :releases, Map.put(ctx.releases, "dep", release)) ++ @on
    assert %{status: :pass} = judge(ctx.proj, report(ctx.proj, tool_run()), opts)
  end

  test "a dependency Mix did not build with its own compilers stays tainted", ctx do
    r = report(ctx.proj, tool_run())

    deps =
      for d <- r.closure["deps"],
          do: if(d["app"] == "dep", do: %{d | "manager" => "rebar3"}, else: d)

    r = %{r | closure: %{r.closure | "deps" => deps}}

    assert %{status: :skip, reason: reason} = judge(ctx.proj, r, ctx.opts ++ @on)

    assert reason ==
             "closure dependency observed the host: dep (native build not set apart: " <>
               "built by rebar3, not Mix)"
  end

  test "cc_precompiler's own reads are set apart as elixir_make's precompiler", ctx do
    File.mkdir_p!(Path.join([ctx.proj, "deps/cc_precompiler/lib"]))
    File.write!(Path.join([ctx.proj, "deps/cc_precompiler/mix.exs"]), "")
    File.mkdir_p!(Path.join([ctx.proj, "_build/host/lib/cc_precompiler/ebin"]))

    File.write!(
      Path.join([ctx.proj, "_build/host/lib/cc_precompiler/ebin/cc_precompiler.app"]),
      "{application,cc_precompiler,[{modules,['Elixir.CCPrecompiler']}]}.\n"
    )

    arch =
      tool(
        15,
        "erlang:system_info/1",
        "os_identity",
        %{"key" => "system_architecture"},
        "Elixir.CCPrecompiler"
      )

    r = report(ctx.proj, tool_run() ++ [arch])

    r = %{
      r
      | closure: %{
          r.closure
          | "deps" => [
              dep(ctx.proj, "elixir_make", []),
              dep(ctx.proj, "cc_precompiler", ["elixir_make"]),
              dep(ctx.proj, "dep", ["elixir_make", "cc_precompiler"]),
              dep(ctx.proj, "pkg", ["dep"])
            ]
        },
        windows: [window("cc_precompiler", 1, 4) | r.windows],
        sentinels: [%{app: "cc_precompiler", ts: 2, integrity_ok: true} | r.sentinels]
    }

    native = ["cc_precompiler" | @native]
    opts = Keyword.put(ctx.opts, :built_check, false) ++ @on
    assert %{status: :pass} = Portability.judge(ctx.proj, "pkg", r, native, opts)

    # Without cc_precompiler on the native list nothing is set apart: a
    # call into it would be no traced event.
    assert %{status: :skip} = Portability.judge(ctx.proj, "pkg", r, @native, opts)

    # Nor with a cc_precompiler outside the reviewed versions, or another
    # Hex package under its name (review M3): then elixir_make is not set
    # apart either.
    for release <- [
          %{@tools["cc_precompiler"] | version: "0.1.9"},
          %{@tools["cc_precompiler"] | name: "ccp"}
        ] do
      opts = Keyword.put(opts, :releases, Map.put(ctx.releases, "cc_precompiler", release))

      assert %{status: :skip, observations: %{"native_build" => []}} =
               Portability.judge(ctx.proj, "pkg", r, native, opts),
             inspect(release)
    end
  end

  # Review M1: the set-apart rests on a dependent being unable to read the
  # dependency's build dir, which holds for the native list only.
  test "a dependency the native list leaves out is not set apart", ctx do
    opts = Keyword.put(ctx.opts, :built_check, false) ++ @on
    v = Portability.judge(ctx.proj, "pkg", report(ctx.proj, tool_run()), ["elixir_make"], opts)
    assert %{status: :skip, reason: reason} = v

    assert reason ==
             "closure dependency observed the host: dep (native build not set apart: " <>
               "not on the native list)"
  end

  # Review M2: `make` runs untraced, so with anything set apart it could
  # drop a module into the package's own ebin before the package compiles,
  # as a firmware target's trace guards (`native_output/2`).
  test "with a native side set apart, a beam in the package's ebin from elsewhere refuses",
       ctx do
    own = "NativeSidePkg#{System.unique_integer([:positive])}"
    write_beam(ctx.proj, "pkg", "defmodule #{own} do\nend\n")
    assert %{status: :pass} = judge(ctx.proj, report(ctx.proj, tool_run()), ctx.opts ++ @on)

    elsewhere = Path.join(ctx.proj, "_build/host/lib/dep/obj/planted.ex")
    File.mkdir_p!(Path.dirname(elsewhere))
    File.write!(elsewhere, "")
    module = "NativeSidePlanted#{System.unique_integer([:positive])}"
    write_beam(ctx.proj, "pkg", "defmodule #{module} do\nend\n", elsewhere)

    assert %{status: :skip, reason: reason} =
             judge(ctx.proj, report(ctx.proj, tool_run()), ctx.opts ++ @on)

    assert reason ==
             "native build not set apart: beam not compiled from the package's own sources: " <>
               "Elixir.#{module}.beam"

    # Nothing set apart (no tool ran, or the option is off): as before.
    assert %{status: :pass} = judge(ctx.proj, report(ctx.proj, []), ctx.opts ++ @on)

    assert %{status: :skip, reason: "closure dependency observed the host: dep (" <> _} =
             judge(ctx.proj, report(ctx.proj, tool_run()), ctx.opts)
  end

  # Review M3: a lock can give the app name elixir_make to any Hex package
  # (`{:elixir_make, "~> 1.0", hex: :other}`), and every frame of the tool
  # is set apart. Only the reviewed Hex packages, in the reviewed versions.
  test "the tool is set apart only as the reviewed Hex package and versions", ctx do
    judged = fn release ->
      releases = Map.put(ctx.releases, "elixir_make", release)

      judge(
        ctx.proj,
        report(ctx.proj, tool_run()),
        Keyword.put(ctx.opts, :releases, releases) ++ @on
      )
    end

    make = @tools["elixir_make"]

    for version <- ["0.7.8", "0.8.4", "0.9.0", "0.10.1"],
        do: assert(%{status: :pass} = judged.(%{make | version: version}), version)

    for release <- [
          %{make | name: "elixir_make_fork"},
          %{make | version: "0.7.7"},
          %{make | version: "0.10.2"},
          %{make | version: "0.11.0"},
          %{make | version: "0.10.1-rc.0"},
          %{make | version: "not a version"},
          nil
        ] do
      assert %{status: :skip, reason: "closure dependency observed the host: dep (" <> inner} =
               judged.(release),
             inspect(release)

      assert inner =~ "in Mix.Tasks.Compile.ElixirMake.run/1", inspect(release)
    end
  end

  # Review L2: a native build file that compiles BEAM code could rewrite a
  # beam Mix compiled and keep its compile info, which `compiled_in?/2`
  # cannot tell. Such a build is not set apart.
  defp with_files(ctx, files) do
    for {path, body} <- files do
      full = Path.join([ctx.proj, "deps/dep", path])
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, body)
    end

    contents = Map.merge(%{"lib/dep.ex" => ctx.source, "mix.exs" => ""}, Map.new(files))

    {"dep", release} =
      NccWorker.TracerFixtures.hex_release(ctx.home, "dep", Map.keys(contents), contents)

    Keyword.put(ctx.opts, :releases, Map.put(ctx.releases, "dep", release)) ++ @on
  end

  test "a native build file that compiles BEAM code keeps the dependency tainted", ctx do
    for {file, body} <- [
          {"Makefile", "all:\n\terlc -o $(MIX_COMPILE_PATH) src/x.erl\n"},
          {"Makefile", "ERLC ?= erlc\nall:\n\t$(ERLC) x.erl\n"},
          {"Makefile.win", "all:\n\telixirc lib/x.ex\n"},
          {"c_src/Makefile", "all:\n\tcp gen/X.beam $(MIX_COMPILE_PATH)\n"},
          {"CMakeLists.txt", "install(FILES Elixir.X.beam DESTINATION ebin)\n"},
          {"c_src/build.mk", "x:\n\terlc y.erl\n"},
          {"GNUmakefile", "x:\n\tERLC x.erl\n"}
        ] do
      File.rm_rf!(Path.join(ctx.proj, "deps/dep/c_src"))

      for f <- ~w(Makefile Makefile.win CMakeLists.txt GNUmakefile),
          do: File.rm_rf!(Path.join(ctx.proj, "deps/dep/" <> f))

      opts = with_files(ctx, [{file, body}])

      assert %{status: :skip, reason: reason} =
               judge(ctx.proj, report(ctx.proj, tool_run()), opts),
             file

      assert reason ==
               "closure dependency observed the host: dep (native build not set apart: " <>
                 "native build file compiles BEAM code: #{file})",
             file
    end
  end

  test "a native build file that writes only priv and objects is set apart", ctx do
    makefile = """
    PRIV = $(MIX_COMPILE_PATH)/../priv
    ERL_CFLAGS ?= -I$(ERTS_INCLUDE_DIR)
    all: $(PRIV)/dep_nif.so
    $(PRIV)/dep_nif.so: c_src/dep.c
    \tmkdir -p $(PRIV) && $(CC) $(ERL_CFLAGS) -shared -o $@ $<
    """

    opts = with_files(ctx, [{"Makefile", makefile}, {"c_src/dep.c", "int x;\n"}])
    assert %{status: :pass} = judge(ctx.proj, report(ctx.proj, tool_run()), opts)
  end

  test "a firmware target's trace is unchanged by the option", ctx do
    plain = judge(ctx.proj, report(ctx.proj, tool_run()), ctx.opts ++ [target: "rpi4"])
    on = judge(ctx.proj, report(ctx.proj, tool_run()), ctx.opts ++ [target: "rpi4"] ++ @on)

    assert Map.delete(plain.observations, "trace_stats") ==
             Map.delete(on.observations, "trace_stats")

    assert plain.status == on.status and plain.reason == on.reason
  end
end
