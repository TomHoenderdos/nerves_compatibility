defmodule NccWorker.Portability.JudgeTest do
  # Starts real `elixir` VMs: one such module at a time (the :real_vm
  # group), alongside the unit suites, so their compiles do not contend.
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.Portability
  alias NccWorker.Portability.{Context, PrivRepro, Rebar}
  alias NccWorker.Tracer.Report

  @moduletag :tmp_dir

  @cnj "portability could not be judged"

  # The mapped libraries the VM started with (the tracer's snapshot).
  @libs %{"nif_check" => "ok", "mapped_libs" => ["/usr/lib/libc.so.6"]}

  # deps/<app> and _build/host/lib/<app>/ebin for `dep` and `pkg` (pkg
  # depends on dep), plus `other`, a closure dependency `pkg` does not reach.
  setup %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf(dir) end)
    proj = Path.join(dir, "proj")

    for app <- ["dep", "pkg", "other"] do
      File.mkdir_p!(Path.join([proj, "deps", app, "lib"]))
      File.mkdir_p!(Path.join([proj, "_build/host/lib", app, "ebin"]))
      File.write!(Path.join([proj, "deps", app, "lib", app <> ".ex"]), "")
      File.write!(Path.join([proj, "deps", app, "mix.exs"]), "")
    end

    File.write!(Path.join(proj, "mix.exs"), "")
    %{proj: proj, dir: dir}
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

  defp window(app, open, close),
    do: %{
      app: app,
      open: open,
      close: close,
      depth_ok: true,
      integrity_ok: true,
      delivered: true,
      libs: @libs
    }

  defp report(proj, overrides \\ %{}) do
    struct!(
      %Report{
        start: Map.merge(%{"otp_root" => "/nonexistent-otp"}, @libs),
        closure: %{
          "packages" => ["pkg"],
          "deps" => [dep(proj, "dep", []), dep(proj, "other", []), dep(proj, "pkg", ["dep"])]
        },
        windows: [window("dep", 10, 20), window("other", 21, 29), window("pkg", 30, 40)],
        sentinels: [
          %{app: "dep", ts: 11, integrity_ok: true, pid: "<0.95.0>"},
          %{app: "other", ts: 22, integrity_ok: true, pid: "<0.95.0>"},
          %{app: "pkg", ts: 31, integrity_ok: true, pid: "<0.95.0>"}
        ],
        stats: %{"kind" => "stats", "calls" => 10, "unjudged" => 0},
        ending:
          %{
            "status" => "ok",
            "depth_ok" => true,
            "final_sentinel" => true,
            "overflow" => false,
            "integrity_ok" => true,
            "delivered" => true
          }
          |> Map.merge(@libs)
      },
      overrides
    )
  end

  defp event(ts, mfa, user_file, channel \\ "os_identity") do
    %{
      "ts" => ts,
      "channel" => channel,
      "mfa" => mfa,
      "arg" => %{},
      "extent" => "frame",
      "first" => %{"module" => "Elixir.X"},
      "user" => %{
        "module" => "Elixir.X",
        "function" => "__MODULE__",
        "arity" => 1,
        "file" => user_file,
        "line" => 2
      }
    }
  end

  defp child(events, extra \\ %{}) do
    Map.merge(
      %{
        start: Map.put(@libs, "app", "x"),
        sentinel?: true,
        compiles: [],
        problems: [],
        events: events,
        # The snapshot a child writes after its compiles (`libs` lines).
        libs: [Map.put(@libs, "kind", "libs")]
      },
      extra
    )
  end

  # Hand-built reports carry no `built` lines: the built check is opted out
  # of here and tested on its own.
  defp judge(proj, report, opts \\ []),
    do: Portability.judge(proj, "pkg", report, [], Keyword.put_new(opts, :built_check, false))

  # A config value as the tracer's snapshot and the manifest carry it.
  defp enc(term),
    do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

  # A report made on Elixir 1.19.5 whose config snapshot is `snapshot`.
  defp traced(proj, events, snapshot) do
    r = report(proj, %{events: events, config_env: snapshot})
    %{r | start: Map.put(r.start, "elixir", "1.19.5")}
  end

  @snap %{entries: %{}, truncated: false}

  # Judge revision 21: the package's own compile writing into its own build
  # priv. The judge alone never passes it: the pass waits for the second
  # build (`Portability.run/3`, `PrivRepro`), and a firmware target's
  # trace, which has none, refuses it as before.
  describe "the package's own priv writes" do
    defp priv_write(proj, ts) do
      path = Path.join(proj, "_build/host/lib/pkg/priv/assets/a.txt")

      %{
        event(ts, "file:write_file/3", Path.join(proj, "deps/pkg/lib/pkg.ex"), "file_write")
        | "arg" => %{"path" => path}
      }
    end

    defp with_priv_file(proj) do
      File.mkdir_p!(Path.join(proj, "_build/host/lib/pkg/priv/assets"))
      File.write!(Path.join(proj, "_build/host/lib/pkg/priv/assets/a.txt"), "a")
    end

    test "hold the pass for a second build", %{proj: proj} do
      with_priv_file(proj)
      r = report(proj, %{events: [priv_write(proj, 35)]})
      v = judge(proj, r, nif_waiver: true)

      assert %{status: :skip, reason: @cnj, compile_env: nil, compile_inputs: nil} = v
      assert %{built_priv: ["assets/a.txt"], compile_inputs: [], dir: dir} = v.priv_repro
      assert dir =~ "_build/host/lib/pkg/priv"
      assert v.observations["problems"] == [PrivRepro.hold_problem()]
      assert [%{"written" => "assets/a.txt", "owner" => "pkg"}] = v.observations["priv_writes"]
      refute Map.has_key?(v.observations["priv_writes"] |> hd(), "refusal")

      # Without such a write, nothing is held.
      assert %{status: :pass, built_priv: []} = judge(proj, report(proj), nif_waiver: true)
    end

    test "refuse in a dependency's window", %{proj: proj} do
      with_priv_file(proj)
      r = report(proj, %{events: [priv_write(proj, 15)]})

      assert %{status: :skip, reason: "closure dependency observed the host: dep" <> _} =
               judge(proj, r, nif_waiver: true)
    end

    test "refuse in a firmware target's trace", %{proj: proj} do
      with_priv_file(proj)
      r = report(proj, %{events: [priv_write(proj, 35)]})

      assert %{status: :skip, reason: "compile-time write outside ebin: file:write_file/3 " <> _} =
               judge(proj, r, nif_waiver: true, target: "rpi4")
    end
  end

  # Judge revision 27: a Mix alias of a closure dependency's own project
  # copying a file of its own source tree onto another, phoenix's
  # `compile: [&copy_core_components/1, "compile"]`. dep and pkg each ship
  # `installer/a.eex` and `priv/t/a.eex`, with a verified Hex release whose
  # files are exactly its source dir's unless `priv:` says otherwise.
  describe "a dependency's copies within its own tree" do
    defp tree_releases(proj, dir, apps, priv \\ "a") do
      home = Path.join(dir, "hex")

      releases =
        for app <- apps, into: %{} do
          for rel <- ["installer/a.eex", "priv/t/a.eex"] do
            File.mkdir_p!(Path.dirname(Path.join([proj, "deps", app, rel])))
          end

          File.write!(Path.join([proj, "deps", app, "installer/a.eex"]), "a")
          File.write!(Path.join([proj, "deps", app, "priv/t/a.eex"]), priv)

          File.ln_s!(
            "../../../../deps/#{app}/priv",
            Path.join([proj, "_build/host/lib", app, "priv"])
          )

          contents = %{
            "lib/#{app}.ex" => "",
            "mix.exs" => "",
            "installer/a.eex" => "a",
            "priv/t/a.eex" => priv
          }

          NccWorker.TracerFixtures.hex_release(home, app, Map.keys(contents), contents)
        end

      [releases: releases, hex_home: home, nif_waiver: true]
    end

    # What `File.cp!/2` traces when a fun of the app's own aliases tail-calls
    # it: Mix's alias runner the first frame, in Mix's own process.
    defp tree_copy(proj, ts, app, mfa, path \\ "priv/t/a.eex") do
      dest = Path.join([proj, "deps", app, path])

      arg =
        if mfa == "file:write_file_info/3",
          do: %{"path" => dest},
          else: %{
            "path" => dest,
            "from" => Path.join([proj, "deps", app, "installer/a.eex"]),
            "from_kind" => "read"
          }

      %{
        event(ts, mfa, nil, "file_write")
        | "arg" => arg,
          "extent" => "dispatcher",
          "user" => nil,
          "first" => %{"module" => "Elixir.Mix.Task", "function" => "run_alias", "arity" => 6}
      }
      |> Map.put("bottom", %{"module" => "Elixir.Kernel.CLI", "function" => "-exec_fun/2-fun-0-"})
      |> Map.put("pid", "<0.95.0>")
      |> Map.put("caller", %{"module" => "Elixir.File", "function" => "do_cp_file", "arity" => 4})
      |> Map.put("caller_kind", "toolchain")
    end

    defp cp_events(proj, ts, app),
      do:
        for(
          mfa <- ~w(file:copy/2 file:copy/3 file:write_file_info/3),
          do: tree_copy(proj, ts, app, mfa)
        )

    defp cp_refusal(proj, app, mfa \\ "file:copy/2"),
      do:
        "compile-time write outside ebin: #{mfa} " <>
          Path.join([proj, "deps", app, "priv/t/a.eex"])

    test "the package's own copy passes when the tarball holds both bytes the same",
         %{proj: proj, dir: dir} do
      opts = tree_releases(proj, dir, ["dep", "pkg"])
      r = report(proj, %{events: cp_events(proj, 35, "pkg")})
      assert %{status: :pass, reason: nil, observations: obs} = v = judge(proj, r, opts)
      assert v.built_priv == []
      assert length(obs["own_tree_copies"]) == 3

      for item <- obs["own_tree_copies"] do
        assert %{"owner" => "pkg", "app" => "pkg", "path" => "priv/t/a.eex"} = item
        refute Map.has_key?(item, "refusal")
      end

      assert %{status: :pass} = judge(proj, r, Keyword.put(opts, :target, "rpi4"))
    end

    test "a dependency's own copy in its window leaves it clean", %{proj: proj, dir: dir} do
      opts = tree_releases(proj, dir, ["dep", "pkg"])
      r = report(proj, %{events: cp_events(proj, 15, "dep")})

      assert %{status: :pass, observations: %{"own_tree_copies" => [_, _, _], "taint" => taint}} =
               judge(proj, r, opts)

      assert taint == %{}
    end

    test "refuses as before when the tree is not the tarball's", %{proj: proj, dir: dir} do
      opts = tree_releases(proj, dir, ["dep", "pkg"])

      for {app, ts} <- [{"pkg", 35}, {"dep", 15}] do
        r = report(proj, %{events: cp_events(proj, ts, app)})
        assert %{status: :pass} = judge(proj, r, opts)

        # A file beside it, the copy's destination changed, no verified
        # tarball: the copy is the write it always was.
        generated = Path.join([proj, "deps", app, "priv/t/b.eex"])
        dest = Path.join([proj, "deps", app, "priv/t/a.eex"])

        for {change, undo} <- [
              {fn -> File.write!(generated, "x") end, fn -> File.rm!(generated) end},
              {fn -> File.write!(dest, "changed") end, fn -> File.write!(dest, "a") end}
            ] do
          change.()
          v = judge(proj, r, opts)
          undo.()
          assert_copy_refused(v, app, cp_refusal(proj, app))
        end

        assert_copy_refused(
          judge(proj, r, Keyword.put(opts, :releases, %{})),
          app,
          cp_refusal(proj, app)
        )
      end
    end

    test "refuses a copy between two names of one file", %{proj: proj, dir: dir} do
      # A hard link made before the compile (an untraced `mix deps.get`
      # evaluates every mix.exs) leaves the tree's bytes the tarball's, but
      # the copy opens its source's own inode for writing: it empties both.
      opts = tree_releases(proj, dir, ["dep", "pkg"])
      r = report(proj, %{events: cp_events(proj, 35, "pkg")})
      assert %{status: :pass} = judge(proj, r, opts)

      source = Path.join(proj, "deps/pkg/installer/a.eex")
      dest = Path.join(proj, "deps/pkg/priv/t/a.eex")
      File.rm!(dest)
      File.ln!(source, dest)

      assert %{status: :skip, reason: reason} = judge(proj, r, opts)
      assert reason == cp_refusal(proj, "pkg")
    end

    test "refuses a copy another dependency's mix.exs makes in the window", %{
      proj: proj,
      dir: dir
    } do
      # pkg's alias runs a fun of dep's own mix.exs (`&Dep.MixProject.swap/1`)
      # that copies by relative paths: Mix runs it in pkg's source dir, so
      # the copy lands in pkg's tree, while its frame names dep's mix.exs.
      opts = tree_releases(proj, dir, ["dep", "pkg"])
      root = Path.join(proj, "deps/dep")

      swap = %{
        "module" => "Elixir.Dep.MixProject",
        "function" => "swap",
        "arity" => 1,
        "file" => Path.join(root, "mix.exs"),
        "line" => 5
      }

      events =
        for mfa <- ~w(file:copy/2 file:copy/3 file:write_file_info/3) do
          e = tree_copy(proj, 35, "dep", mfa)

          arg =
            Map.new(e["arg"], fn
              {k, v} when k in ["path", "from"] -> {k, Path.relative_to(v, root)}
              kv -> kv
            end)

          %{e | "arg" => arg, "extent" => "frame", "user" => swap}
        end

      # In dep's own window the same copies are dep's own.
      assert %{status: :pass} =
               judge(proj, report(proj, %{events: Enum.map(events, &%{&1 | "ts" => 15})}), opts)

      assert %{status: :skip, reason: reason} = judge(proj, report(proj, %{events: events}), opts)

      assert reason ==
               "closure dependency observed the host: dep " <>
                 "(compile-time write outside ebin: file:copy/2 priv/t/a.eex)"
    end

    test "refuses a copy the tarball does not hold the same bytes for", %{proj: proj, dir: dir} do
      # The tree is the tarball's, but the tarball's priv/t/a.eex is not
      # installer/a.eex: copying one onto the other changes it.
      opts = tree_releases(proj, dir, ["dep", "pkg"], "b")
      r = report(proj, %{events: cp_events(proj, 35, "pkg")})
      assert %{status: :skip, reason: reason} = judge(proj, r, opts)
      assert reason == cp_refusal(proj, "pkg")
    end

    test "refuses the mode write on anything but such a copy", %{proj: proj, dir: dir} do
      opts = tree_releases(proj, dir, ["dep", "pkg"])
      mode = "file:write_file_info/3"

      # Alone, and onto another file of the tarball than the copy's.
      for events <- [
            [tree_copy(proj, 35, "pkg", mode)],
            [
              tree_copy(proj, 35, "pkg", "file:copy/2"),
              tree_copy(proj, 36, "pkg", mode, "installer/a.eex")
            ]
          ] do
        v = judge(proj, report(proj, %{events: events}), opts)
        assert v.status == :skip
        assert v.reason =~ "compile-time write outside ebin: #{mode} "
      end

      # Onto another app's copy.
      events = [tree_copy(proj, 15, "dep", "file:copy/2"), tree_copy(proj, 35, "pkg", mode)]
      assert %{status: :skip, reason: reason} = judge(proj, report(proj, %{events: events}), opts)
      assert reason == cp_refusal(proj, "pkg", mode)
    end

    defp assert_copy_refused(v, "pkg", refusal),
      do: assert(%{status: :skip, reason: ^refusal} = v)

    defp assert_copy_refused(v, "dep", refusal) do
      assert %{status: :skip} = v
      assert v.reason == "closure dependency observed the host: dep (#{refusal})"
    end
  end

  # Judge revision 23: a closure dependency's own compile reading a file in
  # its own source priv through Mix's link, rustler's
  # `Mix.Tasks.Rustler.New` embedding its templates. dep and pkg are both
  # natively built here, each with a verified Hex release whose files are
  # exactly its source dir's.
  describe "a dependency's own source priv reads" do
    defp linked_priv(proj, dir, apps) do
      home = Path.join(dir, "hex")

      releases =
        for app <- apps, into: %{} do
          File.mkdir_p!(Path.join([proj, "deps", app, "priv"]))
          File.write!(Path.join([proj, "deps", app, "priv", "t.txt"]), "template of #{app}")

          File.ln_s!(
            "../../../../deps/#{app}/priv",
            Path.join([proj, "_build/host/lib", app, "priv"])
          )

          contents = %{
            "lib/#{app}.ex" => "",
            "mix.exs" => "",
            "priv/t.txt" => "template of #{app}"
          }

          NccWorker.TracerFixtures.hex_release(home, app, Map.keys(contents), contents)
        end

      [releases: releases, hex_home: home, nif_waiver: true]
    end

    defp priv_read(proj, ts, app, owner_file) do
      path = Path.join([proj, "_build/host/lib", app, "priv/t.txt"])
      %{event(ts, "file:read_file/2", owner_file, "file_read") | "arg" => %{"path" => path}}
    end

    defp pjudge(proj, r, opts),
      do:
        Portability.judge(proj, "pkg", r, ["dep", "pkg"], Keyword.put(opts, :built_check, false))

    defp priv_refusal(proj, app, file),
      do:
        "compile-time host read: file:read_file/2 " <>
          Path.join([proj, "_build/host/lib", app, "priv/t.txt"]) <>
          " in X.__MODULE__/1 (#{file}:2)"

    test "the package's own read passes when its tree is its tarball's", %{proj: proj, dir: dir} do
      opts = linked_priv(proj, dir, ["dep", "pkg"])
      r = report(proj, %{events: [priv_read(proj, 35, "pkg", "lib/pkg.ex")]})
      assert %{status: :pass, reason: nil, observations: obs} = v = pjudge(proj, r, opts)
      assert v.built_priv == []

      assert [%{"owner" => "pkg", "app" => "pkg", "source" => "priv/t.txt"} = item] =
               obs["own_priv_reads"]

      refute Map.has_key?(item, "refusal")

      # The same in a firmware target's trace, whose own check of a natively
      # built dependency's tree is the same.
      assert %{status: :pass} = pjudge(proj, r, Keyword.put(opts, :target, "rpi4"))
    end

    test "a dependency's own read in its window leaves it clean", %{proj: proj, dir: dir} do
      opts = linked_priv(proj, dir, ["dep", "pkg"])
      r = report(proj, %{events: [priv_read(proj, 15, "dep", "lib/dep.ex")]})

      assert %{status: :pass, observations: %{"own_priv_reads" => [%{"owner" => "dep"}]}} =
               pjudge(proj, r, opts)

      assert %{status: :pass} = pjudge(proj, r, Keyword.put(opts, :target, "rpi4"))
    end

    test "refuses as before when the tree is not its tarball's", %{proj: proj, dir: dir} do
      opts = linked_priv(proj, dir, ["dep", "pkg"])

      for {app, ts, file} <- [{"pkg", 35, "lib/pkg.ex"}, {"dep", 15, "lib/dep.ex"}] do
        r = report(proj, %{events: [priv_read(proj, ts, app, file)]})
        refusal = priv_refusal(proj, app, file)
        assert %{status: :pass} = pjudge(proj, r, opts)

        # A file the build wrote beside it, the file read changed, no
        # verified tarball: the read is the host read it always was.
        generated = Path.join([proj, "deps", app, "priv", "generated.txt"])
        read = Path.join([proj, "deps", app, "priv", "t.txt"])

        for {change, undo} <- [
              {fn -> File.write!(generated, "x") end, fn -> File.rm!(generated) end},
              {fn -> File.write!(read, "changed") end,
               fn -> File.write!(read, "template of #{app}") end}
            ] do
          change.()
          v = pjudge(proj, r, opts)
          target_v = pjudge(proj, r, Keyword.put(opts, :target, "rpi4"))
          undo.()
          assert_priv_refused(v, app, refusal)
          assert_priv_refused(target_v, app, refusal)
        end

        assert_priv_refused(pjudge(proj, r, Keyword.put(opts, :releases, %{})), app, refusal)
      end
    end

    defp assert_priv_refused(v, "pkg", refusal),
      do: assert(%{status: :skip, reason: ^refusal} = v)

    defp assert_priv_refused(v, "dep", refusal) do
      assert %{status: :skip, reason: reason} = v

      assert reason in [
               "closure dependency observed the host: dep (#{refusal})",
               # A firmware target's trace refuses on the first refusal itself.
               refusal
             ]
    end

    # A firmware target's trace sets elixir_make's own activity apart, and
    # the `make` it runs is no traced process: it may rewrite a file of the
    # tarball in priv (or relink the build priv) before the compile reads
    # it and put the tarball's bytes back before the window closes, or
    # regenerate it with the bytes the tarball happens to hold on this
    # builder. Neither the tree check after the compile nor the digest at
    # window close can tell, so a read in a window `make` ran in keeps its
    # refusal, as any non-beam file `make` may have written does.
    test "a window the native build tool ran in keeps the refusal in a firmware target's trace",
         %{proj: proj, dir: dir} do
      File.mkdir_p!(Path.join([proj, "deps/elixir_make/lib"]))
      File.write!(Path.join([proj, "deps/elixir_make/lib/elixir_make.ex"]), "")
      File.write!(Path.join([proj, "deps/elixir_make/mix.exs"]), "")
      File.mkdir_p!(Path.join([proj, "_build/host/lib/elixir_make/ebin"]))

      File.write!(
        Path.join([proj, "_build/host/lib/elixir_make/ebin/elixir_make.app"]),
        "{application,elixir_make,[{modules,['Elixir.ElixirMake.Compiler']}]}.\n"
      )

      opts = linked_priv(proj, dir, ["dep", "pkg", "elixir_make"])

      make = %{
        event(14, "erlang:open_port/2", "lib/elixir_make/compiler.ex", "programs")
        | "arg" => %{"port" => "{spawn_executable,\"make\"}"},
          "first" => %{"module" => "Elixir.ElixirMake.Compiler"},
          "user" => %{
            "module" => "Elixir.ElixirMake.Compiler",
            "function" => "compile",
            "arity" => 0,
            "file" => "lib/elixir_make/compiler.ex",
            "line" => 2
          }
      }

      base = report(proj)

      r =
        report(proj, %{
          closure: %{
            "packages" => ["pkg"],
            "deps" => [
              dep(proj, "elixir_make", []),
              dep(proj, "dep", ["elixir_make"]),
              dep(proj, "other", []),
              dep(proj, "pkg", ["dep"])
            ]
          },
          windows: [window("elixir_make", 5, 9) | base.windows],
          sentinels: [%{app: "elixir_make", ts: 6, integrity_ok: true} | base.sentinels]
        })

      tjudge = fn events ->
        Portability.judge(
          proj,
          "pkg",
          %{r | events: events},
          ["dep", "pkg", "elixir_make"],
          Keyword.merge(opts, built_check: false, target: "rpi4")
        )
      end

      read = priv_read(proj, 15, "dep", "lib/dep.ex")

      # make alone, set apart, and the read alone pass.
      assert %{status: :pass, observations: %{"native_build" => [_]}} = tjudge.([make])
      assert %{status: :pass} = tjudge.([read])

      # Together, in dep's window, the read is the host read it was.
      assert_priv_refused(tjudge.([make, read]), "dep", priv_refusal(proj, "dep", "lib/dep.ex"))

      # make in another window leaves dep's own read alone.
      assert %{status: :pass} = tjudge.([%{make | "ts" => 7}, read])
    end

    test "the package reading a dependency's priv refuses as before", %{proj: proj, dir: dir} do
      opts = linked_priv(proj, dir, ["dep", "pkg"])
      r = report(proj, %{events: [priv_read(proj, 35, "dep", "lib/pkg.ex")]})
      refusal = priv_refusal(proj, "dep", "lib/pkg.ex")
      assert %{status: :skip, reason: ^refusal} = pjudge(proj, r, opts)

      assert %{status: :skip, reason: ^refusal} =
               pjudge(proj, r, Keyword.put(opts, :target, "rpi4"))

      # And a dependency reading the package's.
      r = report(proj, %{events: [priv_read(proj, 15, "pkg", "lib/dep.ex")]})

      assert %{status: :skip, reason: "closure dependency observed the host: dep" <> _} =
               pjudge(proj, r, opts)
    end
  end

  describe "the mapped-library check" do
    defp with_libs(r, libs), do: %{r | ending: %{r.ending | "mapped_libs" => libs}}

    defp with_window_libs(r, app, libs) do
      windows =
        for w <- r.windows,
            do: if(w.app == app, do: %{w | libs: %{w.libs | "mapped_libs" => libs}}, else: w)

      %{r | windows: windows}
    end

    test "a library first seen at a window's close belongs to that window", %{proj: proj} do
      evil = ["/usr/lib/libc.so.6", "/tmp/evil.so"]
      # Mapped in pkg's window, still mapped at the end.
      r = proj |> report() |> with_window_libs("pkg", evil) |> with_libs(evil)

      assert %{
               status: :skip,
               reason: "compile-time native library load: /tmp/evil.so",
               observations: obs
             } =
               judge(proj, r, nif_waiver: false)

      assert %{"owner" => "pkg", "reason" => "compile-time native library load: /tmp/evil.so"} in obs[
               "refusals"
             ]

      # In the window of `other`, outside pkg's closure, it does not count
      # (it stays mapped through every later snapshot).
      r =
        proj
        |> report()
        |> with_window_libs("other", evil)
        |> with_window_libs("pkg", evil)
        |> with_libs(evil)

      assert %{status: :pass} = judge(proj, r, nif_waiver: false)

      # In dep's window: pkg's closure dependency is tainted.
      r =
        proj
        |> report()
        |> with_window_libs("dep", evil)
        |> with_window_libs("other", evil)
        |> with_window_libs("pkg", evil)
        |> with_libs(evil)

      assert %{
               reason:
                 "closure dependency observed the host: dep (compile-time native library load: /tmp/evil.so)"
             } =
               judge(proj, r, nif_waiver: false)
    end

    test "a library mapped during the compile outside the install refuses", %{proj: proj} do
      r = proj |> report() |> with_libs(["/usr/lib/libc.so.6", "/tmp/evil.so"])

      assert %{status: :skip, reason: "compile-time native library load: /tmp/evil.so"} =
               judge(proj, r, nif_waiver: false)
    end

    test "libraries mapped at start, wherever they live, are ignored", %{proj: proj} do
      r = report(proj)
      assert %{status: :pass} = judge(proj, r, nif_waiver: false)
    end

    test "a native closure dependency's own library is observed, not refused", %{proj: proj} do
      nif = Path.join([proj, "_build/host/lib/dep/priv/dep_nif.so"])
      File.mkdir_p!(Path.dirname(nif))
      File.write!(nif, "")
      r = proj |> report() |> with_libs(["/usr/lib/libc.so.6", nif])

      assert %{status: :pass, observations: %{"native_libs" => [_]}} =
               Portability.judge(proj, "pkg", r, ["dep"], nif_waiver: false, built_check: false)

      # Not native: the same library refuses.
      assert %{status: :skip, reason: "compile-time native library load: " <> _} =
               judge(proj, r, nif_waiver: false)
    end

    test "the package's own dirs are never allowed, native or not", %{proj: proj} do
      nif = Path.join([proj, "_build/host/lib/pkg/priv/pkg_nif.so"])
      File.mkdir_p!(Path.dirname(nif))
      File.write!(nif, "")
      r = proj |> report() |> with_libs(["/usr/lib/libc.so.6", nif])

      assert %{status: :skip, reason: "compile-time native library load: " <> _} =
               Portability.judge(proj, "pkg", r, ["pkg", "dep"],
                 nif_waiver: false,
                 built_check: false
               )
    end

    test "a child VM that compiled but wrote no libs snapshot cannot be judged", %{proj: proj} do
      compiled = %{
        "kind" => "compile",
        "result" => "ok",
        "module" => "dep",
        "source" => "src/dep.erl"
      }

      r = report(proj, %{children: %{"dep" => child([], %{compiles: [compiled], libs: []})}})

      assert %{status: :skip, reason: @cnj, observations: %{"problems" => problems}} =
               judge(proj, r, nif_waiver: false)

      assert "native library check unavailable" in problems
    end

    test "a child VM's new library taints its dependency", %{proj: proj} do
      libs = %{
        "kind" => "libs",
        "nif_check" => "ok",
        "mapped_libs" => ["/usr/lib/libc.so.6", "/tmp/r.so"]
      }

      r = report(proj, %{children: %{"dep" => child([], %{libs: [libs]})}})

      assert %{
               reason:
                 "closure dependency observed the host: dep (compile-time native library load: /tmp/r.so)"
             } = judge(proj, r, nif_waiver: false)
    end

    test "no maps is could-not-judge; the test helper's waiver passes it", %{proj: proj} do
      off = %{"nif_check" => "unavailable", "mapped_libs" => nil}

      r =
        report(proj, %{start: Map.merge(report(proj).start, off)})
        |> then(&%{&1 | ending: Map.merge(&1.ending, off)})

      assert %{status: :skip, reason: @cnj, observations: %{"problems" => problems}} =
               judge(proj, r, nif_waiver: false)

      assert "native library check unavailable" in problems

      assert %{status: :pass, observations: %{"nif_check" => "waived"}} =
               judge(proj, r, nif_waiver: true)
    end
  end

  describe "the verdict" do
    test "a clean trace passes with its stats", %{proj: proj} do
      {proj, report} = clean_judged_project(proj)
      assert %{status: :pass, reason: nil, observations: obs} = judge(proj, report)

      assert %{"calls" => 10, "windows" => 3, "sentinels" => 3, "rebar3_untraced_last" => %{}} =
               obs["trace_stats"]

      assert obs["taint"] == %{}
      assert obs["problems"] == []
      assert obs["refusals"] == []
    end

    test "a refusal in the package's window is the reason", %{proj: proj} do
      r = report(proj, %{events: [event(35, "os:version/0", "lib/pkg.ex")]})

      assert %{
               status: :skip,
               reason: "compile-time host read: os:version/0" <> _,
               observations: obs
             } =
               judge(proj, r)

      assert [%{"owner" => "pkg", "reason" => "compile-time host read: os:version/0" <> _}] =
               obs["refusals"]
    end

    test "a refusal in a dependency's window taints it and refuses the package", %{proj: proj} do
      r = report(proj, %{events: [event(15, "os:version/0", "lib/dep.ex")]})

      assert %{
               status: :skip,
               reason:
                 "closure dependency observed the host: dep (compile-time host read: os:version/0" <>
                   _,
               observations: obs
             } = judge(proj, r)

      assert %{"dep" => "compile-time host read: os:version/0" <> _} = obs["taint"]
    end

    test "a compile-time call into a natively built dependency taints the caller", %{
      proj: proj
    } do
      # dep's compile calls nat (a natively built closure dependency, its NIF
      # loaded from its own dirs): whatever the NIF returned is in dep's
      # beams, which the package may expand or read with no traced event.
      call = %{
        event(15, "nat:cpu_features/0", "lib/dep.ex", "native_closure")
        | "arg" => %{"module" => "nat"}
      }

      r = report(proj, %{events: [call]})

      assert %{
               status: :skip,
               reason:
                 "closure dependency observed the host: dep (calls natively built dependency at compile time: nat:cpu_features/0)",
               observations: obs
             } = judge(proj, r)

      assert [%{"owner" => "dep", "mfa" => "nat:cpu_features/0"}] = obs["native_calls"]
    end

    test "an event outside every window counts against everything", %{proj: proj} do
      r = report(proj, %{events: [event(25 + 100, "os:cmd/1", "lib/x.ex", "programs")]})

      assert %{status: :skip, reason: "compile-time host read: os:cmd/1" <> _} =
               judge(proj, r)
    end

    test "a refusal in the package's window comes before taint", %{proj: proj} do
      r =
        report(proj, %{
          events: [
            %{event(15, "erlang:system_info/1", "lib/dep.ex") | "arg" => %{"key" => "version"}},
            event(35, "os:version/0", "lib/pkg.ex")
          ]
        })

      assert %{reason: "compile-time host read: os:version/0" <> _} = judge(proj, r)
    end

    test "an incomplete trace could not be judged", %{proj: proj} do
      ending = report(proj).ending

      for overrides <- [
            %{ending: nil},
            %{ending: %{ending | "final_sentinel" => false}},
            %{ending: %{ending | "depth_ok" => false}},
            %{ending: %{ending | "integrity_ok" => false}},
            %{ending: %{ending | "delivered" => false}},
            %{ending: Map.delete(ending, "delivered")},
            %{ending: %{ending | "overflow" => true}},
            %{ending: %{ending | "status" => "error"}},
            %{start: nil},
            %{closure: nil},
            %{stats: nil},
            %{stats: %{"unjudged" => 2}},
            %{stats: %{"calls" => 1}},
            %{overflow: [%{"what" => "calls"}]},
            %{problems: ["unparsable line 3"]},
            %{refused_start: %{"why" => "partitions"}},
            %{sentinels: [%{app: "dep", ts: 11, integrity_ok: true}]},
            %{sentinels: [%{app: "dep", ts: 11, integrity_ok: true}, %{app: "pkg", ts: 31}]},
            %{windows: [window("dep", 10, 20), %{window("pkg", 30, 40) | depth_ok: false}]},
            %{windows: [window("dep", 10, 20), %{window("pkg", 30, 40) | integrity_ok: nil}]},
            %{windows: [window("dep", 10, 20), %{window("pkg", 30, 40) | delivered: false}]},
            %{windows: [window("dep", 10, 20), %{window("pkg", 30, 40) | close: nil}]},
            %{windows: [window("dep", 10, 20)]},
            %{windows: [window("pkg", 30, 35), window("pkg", 36, 40)]}
          ] do
        assert %{status: :skip, reason: @cnj, observations: %{"problems" => [_ | _]}} =
                 judge(proj, report(proj, overrides)),
               inspect(overrides)
      end
    end

    test "a package the closure does not name could not be judged", %{proj: proj} do
      r = report(proj)
      r = %{r | closure: %{r.closure | "packages" => ["dep", "other"]}}
      assert %{status: :skip, reason: @cnj, observations: obs} = judge(proj, r)
      assert "package not in the traced closure" in obs["problems"]
    end

    test "a missing sentinel in a dependency's window taints it", %{proj: proj} do
      r =
        report(proj, %{
          sentinels: [
            %{app: "pkg", ts: 31, integrity_ok: true},
            %{app: "other", ts: 22, integrity_ok: true}
          ]
        })

      assert %{
               status: :skip,
               reason: "closure dependency observed the host: dep (sentinel missing" <> _
             } =
               judge(proj, r)
    end

    test "taint names the first tainted dependency in compile order", %{proj: proj} do
      r = report(proj)
      deps = [dep(proj, "dep", []), dep(proj, "other", []), dep(proj, "pkg", ["other", "dep"])]

      r = %{
        r
        | closure: %{r.closure | "deps" => deps},
          events: [
            event(25, "os:version/0", "lib/other.ex"),
            event(15, "os:version/0", "lib/dep.ex")
          ]
      }

      assert %{reason: "closure dependency observed the host: dep (" <> _, observations: obs} =
               judge(proj, r)

      assert Map.keys(obs["taint"]) == ["dep", "other"]
    end
  end

  # The setup's project with a report that passes as it is.
  defp clean_judged_project(proj), do: {proj, report(proj)}

  describe "the byte order (judge revision 13)" do
    defp endian_event(ts, file),
      do: %{event(ts, "erlang:system_info/1", file) | "arg" => %{"key" => "endian"}}

    defp with_endian(report, endian),
      do: %{report | start: Map.put(report.start, "endian", endian)}

    test "the package's own read is a compared input, not a refusal", %{proj: proj} do
      # nx: `System.endianness/0` in lib/nx/floating.ex's module body.
      for endian <- ["little", "big"] do
        r = proj |> report(%{events: [endian_event(35, "lib/pkg.ex")]}) |> with_endian(endian)

        assert %{status: :pass, reason: nil, compile_inputs: inputs} = judge(proj, r)
        assert inputs == [%{"kind" => "endian", "value" => endian}]
      end
    end

    test "a dependency's read no longer taints: the package records it", %{proj: proj} do
      # polaris, nx_image, safetensors: nx read the byte order in its window.
      r = proj |> report(%{events: [endian_event(15, "lib/dep.ex")]}) |> with_endian("little")

      assert %{status: :pass, compile_inputs: [%{"kind" => "endian", "value" => "little"}]} =
               v = judge(proj, r)

      assert v.observations["taint"] == %{}
    end

    test "a read outside the package's closure records nothing", %{proj: proj} do
      r = proj |> report(%{events: [endian_event(25, "lib/other.ex")]}) |> with_endian("little")
      assert %{status: :pass, compile_inputs: []} = judge(proj, r)
    end

    test "a read with no byte order on the start line could not be judged", %{proj: proj} do
      for endian <- [:absent, nil, "native", ""] do
        r = report(proj, %{events: [endian_event(35, "lib/pkg.ex")]})
        r = if endian == :absent, do: r, else: with_endian(r, endian)

        assert %{status: :skip, reason: @cnj, compile_inputs: nil, observations: obs} =
                 judge(proj, r),
               inspect(endian)

        assert "byte order read but not recorded by the tracer" in obs["problems"]
      end
    end

    test "a child VM that ran with another byte order could not be judged", %{proj: proj} do
      kid = child([], %{start: @libs |> Map.put("app", "dep") |> Map.put("endian", "big")})

      r =
        proj
        |> report(%{events: [endian_event(35, "lib/pkg.ex")], children: %{"dep" => kid}})
        |> with_endian("little")

      assert %{status: :skip, reason: @cnj, observations: obs} = judge(proj, r)
      assert "byte order read but not recorded by the tracer" in obs["problems"]
    end

    test "without a read, the start line's byte order changes nothing", %{proj: proj} do
      for endian <- [:absent, "big"] do
        r = report(proj)
        r = if endian == :absent, do: r, else: with_endian(r, endian)
        assert %{status: :pass, compile_inputs: []} = judge(proj, r)
      end
    end

    test "the read is observed for the admin", %{proj: proj} do
      r = proj |> report(%{events: [endian_event(35, "lib/pkg.ex")]}) |> with_endian("little")

      assert %{observations: %{"endian_reads" => [%{"owner" => "pkg", "file" => "lib/pkg.ex"}]}} =
               judge(proj, r)
    end
  end

  describe "a natively built dependency's beam read (judge revision 15)" do
    # dep is natively built (on the native list), with a beam in its ebin and
    # a verified Hex release whose files are exactly deps/dep's. bumblebee
    # on Elixir 1.20: the type checker reads Tokenizers.Tokenizer.beam.
    defp nat_setup(proj, dir) do
      home = Path.join(dir, "hex")

      {"dep", release} =
        NccWorker.TracerFixtures.hex_release(home, "dep", ["lib", "mix.exs"], %{
          "lib/dep.ex" => "",
          "mix.exs" => ""
        })

      module = "JudgeNatDep#{System.unique_integer([:positive])}"
      write_beam(proj, "dep", "defmodule #{module} do\n  def f, do: 1\nend\n")
      beam = Path.join(proj, "_build/host/lib/dep/ebin/Elixir.#{module}.beam")
      %{beam: beam, opts: [releases: %{"dep" => release}, hex_home: home, nif_waiver: false]}
    end

    defp beam_read(ts, path, file \\ "lib/pkg.ex"),
      do: %{event(ts, "prim_file:read_file/1", file, "file_read") | "arg" => %{"path" => path}}

    defp njudge(proj, r, opts, native \\ ["dep"]),
      do: Portability.judge(proj, "pkg", r, native, Keyword.put(opts, :built_check, false))

    defp read_refusal(beam),
      do: "compile-time host read: prim_file:read_file/1 #{beam} in X.__MODULE__/1 (lib/pkg.ex:2)"

    test "is allowed when the dependency's own compile is clean", %{proj: proj, dir: dir} do
      %{beam: beam, opts: opts} = nat_setup(proj, dir)

      for path <- [beam, Path.dirname(beam)] do
        r = report(proj, %{events: [beam_read(35, path)]})
        assert %{status: :pass, reason: nil, observations: obs} = njudge(proj, r, opts)

        assert [%{"owner" => "pkg", "app" => "dep", "mfa" => "prim_file:read_file/1"} = item] =
                 obs["native_beam_reads"]

        refute Map.has_key?(item, "refusal")
      end
    end

    test "refuses as before when the dependency's compile observed the host", %{
      proj: proj,
      dir: dir
    } do
      %{beam: beam, opts: opts} = nat_setup(proj, dir)

      taint = %{
        event(15, "erlang:system_info/1", "lib/dep.ex")
        | "arg" => %{"key" => "system_architecture"}
      }

      # tokenizers: RustlerPrecompiled read the target in its window.
      r = report(proj, %{events: [taint, beam_read(35, beam)]})
      assert %{status: :skip, reason: reason} = njudge(proj, r, opts)
      assert reason == read_refusal(beam)

      # Without the read the dependency's taint refuses, as it always did.
      r = report(proj, %{events: [taint]})

      assert %{reason: "closure dependency observed the host: dep (" <> _} =
               njudge(proj, r, opts)
    end

    test "refuses when the dependency's tree is not its tarball's", %{proj: proj, dir: dir} do
      # A source a native build generated, compiled without a traced read.
      %{beam: beam, opts: opts} = nat_setup(proj, dir)
      File.write!(Path.join(proj, "deps/dep/lib/generated.ex"), "")
      r = report(proj, %{events: [beam_read(35, beam)]})
      assert %{status: :skip, reason: reason} = njudge(proj, r, opts)
      assert reason == read_refusal(beam)

      # No verified tarball at all.
      assert %{status: :skip} = njudge(proj, r, Keyword.put(opts, :releases, %{}))
    end

    test "refuses when native code was loaded or called in the dependency's window", %{
      proj: proj,
      dir: dir
    } do
      %{beam: beam, opts: opts} = nat_setup(proj, dir)
      read = beam_read(35, beam)

      # Its own NIF, mapped at its window's close: its compile may have run it.
      nif = Path.join(proj, "_build/host/lib/dep/priv/dep_nif.so")
      File.mkdir_p!(Path.dirname(nif))
      File.write!(nif, "")
      mapped = ["/usr/lib/libc.so.6", nif]

      windows = for w <- report(proj).windows, do: put_in(w.libs["mapped_libs"], mapped)

      r = report(proj, %{events: [read], windows: windows})
      r = %{r | ending: %{r.ending | "mapped_libs" => mapped}}
      assert %{status: :skip, reason: reason} = njudge(proj, r, opts)
      assert reason == read_refusal(beam)

      # A compile-time call into another natively built dependency.
      call = %{
        event(15, "nat:open/1", "lib/dep.ex", "native_closure")
        | "arg" => %{"module" => "nat"}
      }

      r = report(proj, %{events: [call, read]})
      assert %{status: :skip, reason: reason} = njudge(proj, r, opts)
      assert reason == read_refusal(beam)
    end

    test "refuses when Mix did not build the dependency itself", %{proj: proj, dir: dir} do
      %{beam: beam, opts: opts} = nat_setup(proj, dir)
      r = report(proj, %{events: [beam_read(35, beam)]})

      deps =
        for d <- r.closure["deps"],
            do: if(d["app"] == "dep", do: %{d | "manager" => "make"}, else: d)

      r = %{r | closure: %{r.closure | "deps" => deps}}
      assert %{status: :skip, reason: reason} = njudge(proj, r, opts)
      assert reason == read_refusal(beam)
    end

    test "refuses a read before the dependency's window closed or from a child VM", %{
      proj: proj,
      dir: dir
    } do
      %{beam: beam, opts: opts} = nat_setup(proj, dir)

      # Outside every window, before dep compiled: the host compile's beam.
      r = report(proj, %{events: [beam_read(5, beam)]})
      assert %{status: :skip, reason: reason} = njudge(proj, r, opts)
      assert reason == read_refusal(beam)

      # After every window (Mix's protocol consolidation in host mode) it is
      # allowed for a clean dependency only.
      r = report(proj, %{events: [beam_read(50, beam)]})
      assert %{status: :pass} = njudge(proj, r, opts)

      # The dependency reading its own ebin in its own window.
      r = report(proj, %{events: [beam_read(15, beam, "lib/dep.ex")]})

      assert %{status: :skip, reason: "closure dependency observed the host: dep (" <> _} =
               njudge(proj, r, opts)

      # A child VM's clock is not the Mix VM's.
      r = report(proj, %{children: %{"pkg" => child([beam_read(35, beam)])}})
      assert %{status: :skip, reason: reason} = njudge(proj, r, opts)
      assert reason == read_refusal(beam)
    end

    test "the package's own ebin, natively built, still refuses", %{proj: proj, dir: dir} do
      %{opts: opts} = nat_setup(proj, dir)
      module = "JudgeNatPkg#{System.unique_integer([:positive])}"
      write_beam(proj, "pkg", "defmodule #{module} do\nend\n")
      own = Path.join(proj, "_build/host/lib/pkg/ebin/Elixir.#{module}.beam")
      r = report(proj, %{events: [beam_read(35, own)]})

      assert %{status: :skip, reason: "compile-time host read: prim_file:read_file/1" <> _} =
               njudge(proj, r, opts, ["dep", "pkg"])
    end

    test "every other use of a clean natively built dependency still refuses", %{
      proj: proj,
      dir: dir
    } do
      %{opts: opts} = nat_setup(proj, dir)

      # A compile-time call (a macro, `require`, a struct, a function call in
      # a module body) is the native_closure channel in the package's window.
      call = %{
        event(35, "Elixir.Dep:__using__/1", "lib/pkg.ex", "native_closure")
        | "arg" => %{"module" => "Elixir.Dep"}
      }

      assert %{status: :skip, reason: "calls natively built dependency at compile time: " <> _} =
               njudge(proj, report(proj, %{events: [call]}), opts)

      # An @external_resource or File read of its priv, source or build side.
      for path <- [
            Path.join(proj, "deps/dep/priv/x.h"),
            Path.join(proj, "_build/host/lib/dep/priv/x.h"),
            Path.join(proj, "_build/host/lib/dep/.mix/compile.elixir")
          ] do
        r = report(proj, %{events: [beam_read(35, path)]})

        assert %{status: :skip, reason: "compile-time host read: " <> _} = njudge(proj, r, opts),
               path
      end
    end

    test "the check unavailable passes only under the test waiver", %{proj: proj, dir: dir} do
      %{beam: beam, opts: opts} = nat_setup(proj, dir)
      off = %{"nif_check" => "unavailable", "mapped_libs" => nil}

      r =
        report(proj, %{events: [beam_read(35, beam)], start: Map.merge(report(proj).start, off)})

      r = %{r | ending: Map.merge(r.ending, off)}

      assert %{status: :skip, reason: @cnj} = njudge(proj, r, opts)
      assert %{status: :pass} = njudge(proj, r, Keyword.put(opts, :nif_waiver, true))
    end
  end

  describe "the OS type (judge revision 17)" do
    @linux ["unix", "linux"]
    @rm_rf_caller %{"module" => "Elixir.File", "function" => "rm_rf", "arity" => 1}

    defp os_type_event(ts, file, opts \\ []) do
      e = event(ts, "os:type/0", file)

      case Keyword.get(opts, :caller) do
        nil -> e
        caller -> Map.merge(e, %{"caller" => caller, "caller_kind" => "toolchain"})
      end
    end

    defp with_os_type(report, os_type),
      do: %{report | start: Map.put(report.start, "os_type", os_type)}

    test "the package's own read is a compared input with the whole tuple", %{proj: proj} do
      for os_type <- [@linux, ["unix", "darwin"], ["win32", "nt"]] do
        r = proj |> report(%{events: [os_type_event(35, "lib/pkg.ex")]}) |> with_os_type(os_type)
        [family, name] = os_type

        assert %{status: :pass, reason: nil, compile_inputs: inputs} = judge(proj, r)
        assert inputs == [%{"kind" => "os_type", "family" => family, "name" => name}]
      end
    end

    # kino: File.rm_rf!/1 in Kino.JS.__before_compile__/1 keeps the family alone.
    test "a read only the toolchain's File.rm_rf/1 made records the family", %{proj: proj} do
      r =
        proj
        |> report(%{events: [os_type_event(35, "lib/pkg.ex", caller: @rm_rf_caller)]})
        |> with_os_type(@linux)

      assert %{status: :pass, compile_inputs: [%{"kind" => "os_type", "family" => "unix"}]} =
               judge(proj, r)
    end

    test "one read that reaches the whole tuple records the name", %{proj: proj} do
      r =
        proj
        |> report(%{
          events: [
            os_type_event(15, "lib/dep.ex", caller: @rm_rf_caller),
            os_type_event(35, "lib/pkg.ex")
          ]
        })
        |> with_os_type(@linux)

      assert %{
               status: :pass,
               compile_inputs: [%{"kind" => "os_type", "family" => "unix", "name" => "linux"}]
             } = judge(proj, r)
    end

    test "a dependency's read no longer taints: the package records it", %{proj: proj} do
      r = proj |> report(%{events: [os_type_event(15, "lib/dep.ex")]}) |> with_os_type(@linux)

      assert %{status: :pass, compile_inputs: [%{"kind" => "os_type", "name" => "linux"}]} =
               v = judge(proj, r)

      assert v.observations["taint"] == %{}
    end

    test "a read outside the package's closure records nothing", %{proj: proj} do
      r = proj |> report(%{events: [os_type_event(25, "lib/other.ex")]}) |> with_os_type(@linux)
      assert %{status: :pass, compile_inputs: []} = judge(proj, r)
    end

    test "a read with no OS type on the start line could not be judged", %{proj: proj} do
      for os_type <- [:absent, nil, "unix", ["unix"], ["Unix", "linux"], ["unix", "Linux"], []] do
        r = report(proj, %{events: [os_type_event(35, "lib/pkg.ex")]})
        r = if os_type == :absent, do: r, else: with_os_type(r, os_type)

        assert %{status: :skip, reason: @cnj, compile_inputs: nil, observations: obs} =
                 judge(proj, r),
               inspect(os_type)

        assert "OS type read but not recorded by the tracer" in obs["problems"]
      end
    end

    test "a child VM that ran on another OS type could not be judged", %{proj: proj} do
      kid =
        child([], %{
          start: @libs |> Map.put("app", "dep") |> Map.put("os_type", ["unix", "darwin"])
        })

      r =
        proj
        |> report(%{events: [os_type_event(35, "lib/pkg.ex")], children: %{"dep" => kid}})
        |> with_os_type(@linux)

      assert %{status: :skip, reason: @cnj, observations: obs} = judge(proj, r)
      assert "OS type read but not recorded by the tracer" in obs["problems"]
    end

    test "without a read, the start line's OS type changes nothing", %{proj: proj} do
      assert %{status: :pass, compile_inputs: []} =
               judge(proj, with_os_type(report(proj), @linux))
    end

    test "os:version/0 next to it still refuses", %{proj: proj} do
      r =
        proj
        |> report(%{
          events: [os_type_event(30, "lib/pkg.ex"), event(35, "os:version/0", "lib/pkg.ex")]
        })
        |> with_os_type(@linux)

      assert %{status: :skip, reason: "compile-time host read: os:version/0" <> _} =
               judge(proj, r)
    end

    test "the read is observed for the admin", %{proj: proj} do
      r = proj |> report(%{events: [os_type_event(35, "lib/pkg.ex")]}) |> with_os_type(@linux)

      assert %{observations: %{"os_type_reads" => [%{"owner" => "pkg", "scope" => "full"}]}} =
               judge(proj, r)
    end
  end

  describe "built outside the trace" do
    # The digest each app's build dir has now, as the tracer records it.
    defp built_now(proj, apps) do
      for app <- apps, into: %{} do
        {:ok, digest, files} = :ncc_tracer_digest.dir(Path.join([proj, "_build/host/lib", app]))
        {app, %{digest: digest, files: files, error: nil}}
      end
    end

    defp problems(%{status: :skip, reason: @cnj, observations: %{"problems" => problems}}),
      do: problems

    test "the check runs unless turned off; turned off, a report needs no built lines",
         %{proj: proj} do
      {proj, report} = clean_judged_project(proj)
      assert %{status: :pass} = Portability.judge(proj, "pkg", report, [], built_check: false)

      for opts <- [[], [built_check: true]] do
        assert %{status: :skip, reason: @cnj, observations: %{"problems" => problems}} =
                 Portability.judge(proj, "pkg", report, [], opts)

        assert Enum.sort(problems) == [
                 "built outside the trace: dep (no digest recorded)",
                 "built outside the trace: pkg (no digest recorded)"
               ]
      end
    end

    test "the package's own build rewritten after its digest is not judged", %{proj: proj} do
      {proj, report} = clean_judged_project(proj)
      report = %{report | built: built_now(proj, ["dep", "pkg"])}

      File.write!(
        Path.join([proj, "_build/host/lib/pkg/ebin/pkg.app"]),
        "{application, pkg, []}."
      )

      assert problems(judge(proj, report, built_check: true)) == [
               "built outside the trace: pkg"
             ]
    end

    test "no time left in the budget: every dependency not yet checked is not judged",
         %{proj: proj} do
      {proj, report} = clean_judged_project(proj)
      report = %{report | built: built_now(proj, ["dep", "pkg"])}

      assert problems(judge(proj, report, built_check: true, built_budget_ms: 0)) == [
               "built outside the trace: dep (no time left)",
               "built outside the trace: pkg (no time left)"
             ]
    end

    test "the budget is shared by the closure: what is checked after it ran out is not judged",
         %{proj: proj} do
      {proj, report} = clean_judged_project(proj)
      report = %{report | built: built_now(proj, ["dep", "pkg"])}
      # The start, then dep's check, both at 0; pkg's check after the budget.
      ticks = :counters.new(1, [])

      clock = fn ->
        :counters.add(ticks, 1, 1)
        if :counters.get(ticks, 1) <= 2, do: 0, else: 1_000
      end

      assert problems(
               judge(proj, report, built_check: true, built_budget_ms: 500, built_clock: clock)
             ) == ["built outside the trace: pkg (no time left)"]
    end

    test "a closure whose builds match their recorded digests passes", %{proj: proj} do
      {proj, report} = clean_judged_project(proj)

      File.write!(
        Path.join([proj, "_build/host/lib/dep/ebin/dep.app"]),
        "{application, dep, []}."
      )

      # `other` is outside pkg's closure: it needs no digest.
      report = %{report | built: built_now(proj, ["dep", "pkg"])}

      assert %{status: :pass} = judge(proj, report, built_check: true)
    end

    test "each way a closure dependency fails the check has its own reason", %{proj: proj} do
      {proj, report} = clean_judged_project(proj)
      built = built_now(proj, ["dep", "pkg"])

      cases = [
        {Map.delete(built, "dep"), "built outside the trace: dep (no digest recorded)"},
        {%{built | "dep" => %{digest: nil, files: nil, error: nil}},
         "built outside the trace: dep (no digest recorded)"},
        {%{built | "dep" => %{digest: nil, files: nil, error: "changed"}},
         "built outside the trace: dep (digest failed at window close: changed)"},
        {%{built | "dep" => %{digest: nil, files: nil, error: "digest_unavailable"}},
         "built outside the trace: dep (digest failed at window close: digest_unavailable)"},
        {%{built | "dep" => %{built["dep"] | digest: String.duplicate("0", 64)}},
         "built outside the trace: dep"}
      ]

      for {built, problem} <- cases do
        problems = problems(judge(proj, %{report | built: built}, built_check: true))
        assert problems == [problem], inspect(built)
      end
    end

    test "a build rewritten after its digest was taken is not judged", %{proj: proj} do
      {proj, report} = clean_judged_project(proj)
      report = %{report | built: built_now(proj, ["dep", "pkg"])}
      priv = Path.join(proj, "_build/host/lib/dep/priv")
      File.mkdir_p!(priv)
      File.write!(Path.join(priv, "data.txt"), "restored")

      assert problems(judge(proj, report, built_check: true)) == [
               "built outside the trace: dep"
             ]
    end

    test "a build that cannot be digested now is not judged", %{proj: proj, dir: dir} do
      {proj, report} = clean_judged_project(proj)
      report = %{report | built: built_now(proj, ["dep", "pkg"])}
      outside = Path.join(dir, "outside.beam")
      File.write!(outside, "elsewhere")
      File.ln_s!(outside, Path.join([proj, "_build/host/lib/dep/ebin/Elixir.Out.beam"]))

      problems = problems(judge(proj, report, built_check: true))
      assert Enum.any?(problems, &(&1 =~ ~r/^built outside the trace: dep \(digest failed now: /))
    end

    test "a closure dependency without a build dir is not judged", %{proj: proj} do
      {proj, report} = clean_judged_project(proj)
      # A build path that is not absolute is no build dir at all (`Context`).
      deps =
        for d <- report.closure["deps"],
            do: if(d["app"] == "dep", do: %{d | "build" => "_build/host/lib/dep"}, else: d)

      report = %{
        report
        | built: built_now(proj, ["dep", "pkg"]),
          closure: %{report.closure | "deps" => deps}
      }

      assert "built outside the trace: dep (no build dir)" in problems(
               judge(proj, report, built_check: true)
             )
    end
  end

  describe "fail closed" do
    test "an event Events could not judge makes the verdict could-not-judge", %{proj: proj} do
      unjudged = %{event(35, "os:version/0", "lib/pkg.ex") | "extent" => "unjudged"}
      unknown = event(35, "x:y/0", "lib/pkg.ex", "no_such_channel")
      malformed = %{"ts" => 35, "mfa" => "os:version/0"}
      # Even attributed to our own wrapper mix.exs, to a dependency outside the
      # package's closure, or to a native-pattern quiet interval.
      wrapper = put_in(unjudged, ["user", "file"], Path.join(proj, "mix.exs"))
      other = %{unjudged | "ts" => 25}
      quiet = %{unjudged | "ts" => 55}

      for e <- [unjudged, unknown, malformed, wrapper, other, quiet] do
        r =
          report(proj, %{
            events: [e],
            quiet: [%{app: "dep", open: 50, close: 60, delivered: true}]
          })

        assert %{status: :skip, reason: @cnj, observations: %{"problems" => problems}} =
                 judge(proj, r),
               inspect(e)

        assert Enum.any?(problems, &String.starts_with?(&1, @cnj <> " (")), inspect(problems)
      end
    end

    test "an unjudged event in a closure child VM could not be judged", %{proj: proj} do
      e = %{event(1, "os:version/0", "src/dep.erl") | "extent" => "unjudged"}
      r = report(proj, %{children: %{"dep" => child([e])}})
      assert %{status: :skip, reason: @cnj} = judge(proj, r)
    end

    test "a forged tracer request is an unjudged integrity event", %{proj: proj} do
      forged = %{
        "ts" => 35,
        "channel" => "integrity",
        "mfa" => "ncc_tracer:forged_request",
        "arg" => %{"request" => "finish"},
        "extent" => "unjudged",
        "first" => nil,
        "user" => nil
      }

      assert %{status: :skip, reason: @cnj} = judge(proj, report(proj, %{events: [forged]}))
    end

    test "a user-extent integrity event refuses in any window, quiet included", %{proj: proj} do
      integrity = event(35, "erlang:process_info/2", "lib/pkg.ex", "integrity")

      for {ts, reason} <- [
            {35, "compile-time tracing or system flag: "},
            {125, "compile-time tracing or system flag: "},
            {55, "compile-time tracing or system flag: "},
            {15, "closure dependency observed the host: dep (compile-time tracing"}
          ] do
        r =
          report(proj, %{
            events: [%{integrity | "ts" => ts}],
            quiet: [%{app: "dep", open: 50, close: 60, delivered: true}]
          })

        assert %{status: :skip, reason: got} = judge(proj, r)
        assert String.starts_with?(got, reason), "#{ts}: #{got}"
      end
    end

    test "other events in a quiet interval are the tracer's own and dropped", %{proj: proj} do
      r =
        report(proj, %{
          events: [event(55, "os:version/0", "x.erl")],
          quiet: [%{app: "dep", open: 50, close: 60, delivered: true}]
        })

      assert %{status: :pass} = judge(proj, r)
    end

    test "a stray child trace with no closure owner is ignored", %{proj: proj} do
      stray =
        child([
          event(1, "os:version/0", "x.erl"),
          %{event(2, "os:getenv/1", "x.erl", "env") | "extent" => "unjudged"},
          event(3, "erlang:process_info/2", "x.erl", "integrity")
        ])

      r = report(proj, %{children: %{"unknown" => %{stray | start: %{"app" => "unknown"}}}})
      assert %{status: :pass, observations: obs} = judge(proj, r)
      assert obs["refusals"] == []
    end

    test "child VM events count against their app, not the Mix VM's window", %{proj: proj} do
      # ts 35 is inside pkg's window in the Mix VM clock; it belongs to dep.
      r = report(proj, %{children: %{"dep" => child([event(35, "os:version/0", "src/dep.erl")])}})

      assert %{reason: "closure dependency observed the host: dep (compile-time host read" <> _} =
               judge(proj, r)
    end

    test "only the package's closure counts", %{proj: proj} do
      config = %{
        event(25, "application:get_env/2", "lib/other.ex", "config")
        | "arg" => %{"app" => "fx", "key" => "k"}
      }

      r =
        report(proj, %{
          events: [event(25, "os:version/0", "lib/other.ex"), config],
          children: %{"other" => child([event(1, "os:version/0", "src/other.erl")])}
        })

      assert %{status: :pass, observations: obs} = judge(proj, r)
      assert obs["refusals"] == []
      assert obs["config_reads"] == []
      assert obs["taint"] == %{}
    end

    test "an integrity refusal outside the package's closure still refuses",
         %{proj: proj} do
      integrity = event(25, "erlang:process_info/2", "lib/other.ex", "integrity")

      # In a closure dependency's window that the package does not reach.
      assert %{
               status: :skip,
               reason: "compile-time tracing or system flag: " <> _,
               observations: obs
             } =
               judge(proj, report(proj, %{events: [integrity]}))

      assert [%{"owner" => "outside"}] = obs["refusals"]

      # In that dependency's child VM.
      r = report(proj, %{children: %{"other" => child([%{integrity | "ts" => 1}])}})

      assert %{status: :skip, reason: "compile-time tracing or system flag: " <> _} =
               judge(proj, r)
    end

    test "taint is transitive: package -> b -> a, a tainted refuses the package", %{proj: proj} do
      r = report(proj)

      deps = [
        dep(proj, "dep", []),
        dep(proj, "other", ["dep"]),
        dep(proj, "pkg", ["other"])
      ]

      r = %{
        r
        | closure: %{r.closure | "deps" => deps},
          events: [event(15, "os:version/0", "lib/dep.ex")]
      }

      assert %{
               status: :skip,
               reason: "closure dependency observed the host: dep (compile-time host read" <> _,
               observations: %{"taint" => %{"dep" => _}}
             } = judge(proj, r)
    end

    test "a judge that raises is could-not-judge, never a crash", %{proj: proj} do
      assert %{status: :skip, reason: @cnj} = judge(proj, report(proj, %{events: :garbage}))
      assert %{status: :skip, reason: @cnj} = judge(proj, report(proj, %{windows: ["garbage"]}))
      assert %{status: :skip, reason: @cnj} = Portability.judge(proj, "pkg", %{}, [])
    end
  end

  describe "observations" do
    test "config reads are observed with their owner and recorded", %{proj: proj} do
      config = %{
        "ts" => 35,
        "channel" => "config",
        "mfa" => "application:get_env/2",
        "arg" => %{
          "app" => "fx",
          "key" => "k",
          "app_name" => "fx",
          "key_name" => "k",
          "atoms" => true
        },
        "extent" => "frame",
        "first" => %{"module" => "Elixir.X"},
        "first_kind" => "user",
        "user" => %{"module" => "Elixir.X"}
      }

      snap = %{@snap | entries: %{{"fx", "k"} => enc({:ok, 1})}}

      assert %{
               status: :pass,
               compile_env: [%{app: "fx", path: ["k"], value: value}],
               observations: %{
                 "config_reads" => [
                   %{"owner" => "pkg", "arg" => %{"key" => "k"}, "first" => "Elixir.X"}
                 ]
               }
             } = judge(proj, traced(proj, [config], snap))

      assert value == enc({:ok, 1})
    end

    test "config reads are capped at 200", %{proj: proj} do
      keys = for n <- 1..250, do: "k#{n}"

      events =
        for key <- keys do
          %{
            event(35, "application:get_env/2", "lib/pkg.ex", "config")
            | "arg" => %{
                "app" => "fx",
                "key" => key,
                "app_name" => "fx",
                "key_name" => key,
                "atoms" => true
              }
          }
        end

      snap = %{@snap | entries: Map.new(keys, &{{"fx", &1}, enc({:ok, 1})})}

      assert %{status: :pass, compile_env: items, observations: %{"config_reads" => reads}} =
               judge(proj, traced(proj, events, snap))

      assert length(reads) == 200
      assert length(items) == 250
    end
  end

  describe "R4 through Events (MixExsSlice)" do
    setup %{proj: proj} do
      File.write!(Path.join([proj, "deps", "dep", "mix.exs"]), """
      defmodule Dep.MixProject do
        use Mix.Project
        def project, do: [app: :dep, version: "1.0.0", deps: deps(), elixirc_options: opts()]
        defp deps, do: [{:x, System.get_env("XV") || "~> 1.0"}]
        defp opts, do: [debug_info: System.get_env("DBG") == "1"]
      end
      """)

      :ok
    end

    defp mix_exs_read(proj, line) do
      15
      |> event("inet:gethostname/0", Path.join([proj, "deps", "dep", "mix.exs"]), "network")
      |> put_in(["user", "line"], line)
    end

    defp mix_exs_env_read(proj, line) do
      %{
        event(15, "os:getenv/1", Path.join([proj, "deps", "dep", "mix.exs"]), "env")
        | "arg" => %{"name" => "XV"}
      }
      |> Map.merge(%{"call_id" => line, "returned" => enc(:error)})
      |> put_in(["user", "line"], line)
    end

    test "an allowed mix.exs read is observed; a compile-relevant one taints", %{proj: proj} do
      assert %{status: :pass, observations: %{"mix_exs_allowed" => [%{"owner" => "dep"}]}} =
               judge(proj, report(proj, %{events: [mix_exs_read(proj, 4)]}))

      r = report(proj, %{events: [mix_exs_read(proj, 4), mix_exs_read(proj, 5)]})

      assert %{
               reason:
                 "closure dependency observed the host: dep (compile-time host read in mix.exs: inet:gethostname/0 sets elixirc_options" <>
                   _
             } = judge(proj, r)
    end

    test "an env read in mix.exs is an input only where it reaches a compile key", %{proj: proj} do
      assert %{status: :pass, compile_inputs: []} =
               judge(proj, report(proj, %{events: [mix_exs_env_read(proj, 4)]}))

      assert %{
               status: :pass,
               compile_inputs: [%{"kind" => "env", "name" => "XV", "set_by" => "host"}]
             } =
               judge(proj, report(proj, %{events: [mix_exs_env_read(proj, 5)]}))
    end

    test "an Elixir version read only a compile-relevant key reaches taints", %{proj: proj} do
      version_read = fn line ->
        15
        |> event(
          "System.version/0",
          Path.join([proj, "deps", "dep", "mix.exs"]),
          "elixir_version"
        )
        |> put_in(["user", "line"], line)
      end

      assert %{status: :pass, observations: %{"elixir_version" => []}} =
               judge(proj, report(proj, %{events: [version_read.(4)]}))

      assert %{
               reason:
                 "closure dependency observed the host: dep (compile-time Elixir patch dependence: System.version/0 sets elixirc_options" <>
                   _
             } = judge(proj, report(proj, %{events: [version_read.(5)]}))
    end

    test "a MixExsSlice reason passes through unchanged, for every read in the file",
         %{proj: proj} do
      File.write!(Path.join([proj, "deps", "dep", "mix.exs"]), """
      defmodule Dep.MixProject do
        use Mix.Project
        def project, do: [app: :dep, version: "1.0.0", deps: deps()]
        defp deps, do: [{:x, System.get_env("XV") || "~> 1.0"}]
        def x, do: Code.eval_string("1")
      end
      """)

      r = report(proj, %{events: [mix_exs_read(proj, 4)]})
      assert %{reason: reason, observations: obs} = judge(proj, r)
      assert reason =~ "mix.exs evaluates code dynamically"
      assert [_] = obs["refusals"]
    end
  end

  describe "Context inputs: lock snapshot, Hex cache" do
    # pkg's verified tarball lists lib/; the lock entry for it is `releases`.
    defp hex_home(dir) do
      home = Path.join(dir, "hex")
      File.mkdir_p!(Path.join(home, "packages/hexpm"))
      meta = ~s({<<"files">>,[<<"lib">>,<<"mix.exs">>]}.\n)
      tar = Path.join(dir, "pkg.tar")

      :ok =
        :erl_tar.create(String.to_charlist(tar), [{~c"VERSION", "3"}, {~c"metadata.config", meta}])

      bytes = File.read!(tar)
      File.write!(Path.join(home, "packages/hexpm/pkg-1.0.0.tar"), bytes)
      sum = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
      {home, %{"pkg" => %{name: "pkg", version: "1.0.0", checksum: sum}}}
    end

    test "source reads are judged against the snapshot's verified file list", %{
      proj: proj,
      dir: dir
    } do
      {home, releases} = hex_home(dir)

      read = %{
        event(35, "file:read_file/1", "lib/pkg.ex", "file_read")
        | "arg" => %{"path" => Path.join([proj, "deps", "pkg", "lib", "pkg.ex"])}
      }

      r = report(proj, %{events: [read]})
      assert %{status: :pass} = judge(proj, r, releases: {:ok, releases}, hex_home: home)

      assert %{status: :skip, reason: "compile-time host read: file:read_file/1" <> _} =
               judge(proj, r, releases: %{}, hex_home: home)

      # A lock rewritten after the snapshot is not consulted.
      File.write!(Path.join(proj, "mix.lock"), "%{}\n")
      assert %{status: :pass} = judge(proj, r, releases: releases, hex_home: home)
    end
  end

  describe "R2 (BuildRoot)" do
    defp write_beam(proj, app, source) do
      ebin = Path.join([proj, "_build/host/lib", app, "ebin"])

      for {module, binary} <-
            Code.compile_string(source, Path.join([proj, "deps", app, "lib", app <> ".ex"])) do
        File.write!(Path.join(ebin, "#{module}.beam"), binary)
        :code.purge(module)
        :code.delete(module)
      end
    end

    test "a bare closure source path is observed and passes", %{proj: proj} do
      file = Context.realpath(Path.join([proj, "deps", "pkg", "lib", "pkg.ex"]))
      write_beam(proj, "pkg", "defmodule JudgeR2Obs do\n  def f, do: #{inspect(file)}\nend\n")

      assert %{status: :pass, observations: %{"build_root_source_path" => [%{"owner" => "pkg"}]}} =
               judge(proj, report(proj))
    end

    test "a template root only __mix_recompile__?/0 holds is observed, for a dependency too",
         %{proj: proj} do
      lib = Context.realpath(Path.join([proj, "deps", "pkg", "lib"]))

      source = """
      defmodule JudgeR2Tpl do
        def __mix_recompile__?, do: <<0>> != hash(#{inspect(lib)})
        defp hash(root), do: root |> Path.wildcard() |> :erlang.md5()
      end
      """

      write_beam(proj, "pkg", source)

      assert %{
               status: :pass,
               observations: %{
                 "build_root_recompile_dir" => [%{"owner" => "pkg", "path" => path}]
               }
             } = judge(proj, report(proj))

      assert path == "<root>/deps/pkg/lib"

      File.rm!(Path.join([proj, "_build/host/lib/pkg/ebin", "Elixir.JudgeR2Tpl.beam"]))
      write_beam(proj, "dep", String.replace(source, "JudgeR2Tpl", "JudgeR2TplDep"))

      assert %{
               status: :pass,
               observations: %{"build_root_recompile_dir" => [%{"owner" => "dep"}]}
             } =
               judge(proj, report(proj))
    end

    test "a baked build path refuses the package and taints a dependency", %{proj: proj} do
      baked =
        "defmodule JudgeR2Bake do\n  def f, do: #{inspect(Path.join(proj, "x") <> " y")}\nend\n"

      write_beam(proj, "pkg", baked)
      assert %{reason: "bakes the build path: " <> _} = judge(proj, report(proj))

      File.rm!(Path.join([proj, "_build/host/lib/pkg/ebin", "Elixir.JudgeR2Bake.beam"]))
      write_beam(proj, "dep", String.replace(baked, "JudgeR2Bake", "JudgeR2BakeDep"))

      assert %{reason: "closure dependency observed the host: dep (bakes the build path: " <> _} =
               judge(proj, report(proj))
    end

    test "an unparsable beam or a missing ebin could not be judged", %{proj: proj} do
      for app <- ["pkg", "dep"] do
        ebin = Path.join([proj, "_build/host/lib", app, "ebin"])
        File.write!(Path.join(ebin, "bad.beam"), "not a beam")
        assert %{status: :skip, reason: @cnj, observations: obs} = judge(proj, report(proj)), app
        assert Enum.any?(obs["problems"], &(&1 =~ "unreadable beam bad"))
        File.rm!(Path.join(ebin, "bad.beam"))

        File.rm_rf!(ebin)
        assert %{status: :skip, reason: @cnj} = judge(proj, report(proj)), app
        File.mkdir_p!(ebin)
      end

      # A dependency R2 cannot read is not hidden behind its rebar3 coverage.
      r = report(proj)
      deps = [dep(proj, "dep", [], "rebar3"), dep(proj, "other", []), dep(proj, "pkg", ["dep"])]
      File.rm_rf!(Path.join([proj, "_build/host/lib/dep/ebin"]))
      assert %{reason: @cnj} = judge(proj, %{r | closure: %{r.closure | "deps" => deps}})
    end
  end

  describe "rebar3 in the judge" do
    # Mix writes `_build/<env>/lib/<app>/mix.rebar.config` (its view of the
    # dependency's rebar.config) before it runs rebar3; the judge reads the
    # rebar.config itself from the verified Hex tarball (`rebar_opts/2`).
    defp rebar_report(proj, rebar_app, children) do
      r = report(proj, %{children: children})

      source =
        case File.read(Path.join([proj, "deps", rebar_app, "rebar.config"])) do
          {:ok, text} -> text
          {:error, _} -> ""
        end

      File.write!(Path.join([proj, "_build/host/lib", rebar_app, "mix.rebar.config"]), source)

      deps =
        for d <- r.closure["deps"],
            do: if(d["app"] == rebar_app, do: %{d | "manager" => "rebar3"}, else: d)

      %{r | closure: %{r.closure | "deps" => deps}}
    end

    # The Hex cache and lock entries whose tarballs hold each app's
    # `deps/<app>/rebar.config` as it is now (`tarball:` overrides one).
    defp rebar_opts(proj, apps, tarball \\ %{}) do
      home = Path.join(Path.dirname(proj), "hex-#{System.unique_integer([:positive])}")

      releases =
        Map.new(apps, fn app ->
          contents = Map.get_lazy(tarball, app, fn -> disk_contents(proj, app) end)
          {^app, release} = NccWorker.TracerFixtures.hex_release(home, app, ["src"], contents)
          {app, release}
        end)

      [releases: releases, hex_home: home]
    end

    defp disk_contents(proj, app) do
      case File.read(Path.join([proj, "deps", app, "rebar.config"])) do
        {:ok, text} -> %{"rebar.config" => text}
        {:error, _} -> %{"README" => ""}
      end
    end

    defp rjudge(proj, app, children, apps \\ nil),
      do: judge(proj, rebar_report(proj, app, children), rebar_opts(proj, apps || [app]))

    # A real (R2-clean) beam of an empty module `Elixir.<name>`.
    defp beam!(proj, app, name), do: write_beam(proj, app, "defmodule #{name} do\nend\n")

    # A child's compile line for `module`, with the sha256 of its beam in
    # `app`'s build ebin as the tracer takes it when the compile returns.
    defp compiled_line(proj, app, module) do
      beam = File.read!(Path.join([proj, "_build/host/lib", app, "ebin", module <> ".beam"]))
      sha = :sha256 |> :crypto.hash(beam) |> Base.encode16(case: :lower)
      %{"result" => "ok", "module" => module, "beam_sha256" => sha}
    end

    test "the package: hooks refuse, missing coverage could not be judged", %{proj: proj} do
      File.write!(
        Path.join([proj, "deps/pkg/rebar.config"]),
        ~s({pre_hooks, [{compile, "make"}]}.\n)
      )

      assert %{reason: "rebar3 build runs pre_hooks"} =
               rjudge(proj, "pkg", %{})

      File.write!(Path.join([proj, "deps/pkg/rebar.config"]), "{erl_opts, []}.\n")
      assert %{status: :pass} = rjudge(proj, "pkg", %{"pkg" => child([])})
      assert %{status: :skip, reason: @cnj} = rjudge(proj, "pkg", %{})

      # Beams the trace never saw compiled (two: past the one-gap allowance).
      for m <- ["JudgeRebarA", "JudgeRebarB"], do: beam!(proj, "pkg", m)
      assert %{status: :skip, reason: @cnj} = rjudge(proj, "pkg", %{})
    end

    # Review S1: a host read listed first must not hide the package's or a
    # dependency's rebar3 refusal. Each rebar3 refusal is recorded in
    # `observations["rebar"]`, and a target verdict carries every refusal
    # text, uncut, for the firmware judge (`NccWorker.FirmwareJudge`).
    test "a rebar3 refusal behind an earlier host read is recorded", %{proj: proj} do
      File.write!(
        Path.join([proj, "deps/pkg/rebar.config"]),
        ~s({pre_hooks, [{compile, "make"}]}.\n)
      )

      read = event(35, "inet:gethostname/0", Path.join(proj, "deps/pkg/lib/pkg.ex"), "network")
      r = %{rebar_report(proj, "pkg", %{}) | events: [read]}

      for opts <- [[], [target: "rpi4"]] do
        verdict = judge(proj, r, rebar_opts(proj, ["pkg"]) ++ opts)
        assert verdict.reason =~ "compile-time host read: inet:gethostname/0", inspect(opts)
        assert verdict.observations["rebar"] == %{"pkg" => "rebar3 build runs pre_hooks"}
      end

      verdict = judge(proj, r, rebar_opts(proj, ["pkg"]) ++ [target: "rpi4"])
      assert "rebar3 build runs pre_hooks" in verdict.refusal_texts
      assert Enum.any?(verdict.refusal_texts, &(&1 =~ "inet:gethostname/0"))
    end

    test "a dependency: plugins and missing coverage taint", %{proj: proj} do
      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{plugins, [pc]}.\n")

      assert %{reason: "closure dependency observed the host: dep (rebar3 build runs plugins)"} =
               rjudge(proj, "dep", %{})

      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{erl_opts, []}.\n")
      beam!(proj, "dep", "JudgeRebarD1")

      assert %{
               reason: "closure dependency observed the host: dep (rebar3 compile was not traced)"
             } =
               rjudge(proj, "dep", %{})

      sentinel_lost =
        child([], %{
          sentinel?: false,
          compiles: [%{"result" => "ok", "module" => "Elixir.JudgeRebarD1"}]
        })

      assert %{
               reason: "closure dependency observed the host: dep (rebar3 trace sentinel missing)"
             } =
               rjudge(proj, "dep", %{"dep" => sentinel_lost})
    end

    # Review S5 B1: N is natively built (c_src) and its compile hook runs
    # `make`, which rewrites a header N ships from the host; P includes it.
    # rebar3 runs the hook untraced and N's tree is not checked after the
    # compile, so the hook refuses N and taints P.
    test "a natively built dependency's shell compile hook taints its dependents",
         %{proj: proj} do
      File.mkdir_p!(Path.join(proj, "deps/dep/c_src"))
      File.mkdir_p!(Path.join(proj, "deps/dep/include"))
      File.write!(Path.join(proj, "deps/dep/include/n_config.hrl"), "-define(WORD, 64).\n")

      File.write!(
        Path.join([proj, "deps/dep/rebar.config"]),
        ~s'{pre_hooks, [{"(linux|darwin)", compile, "make -C c_src"}]}.\n'
      )

      header =
        35
        |> event("file:read_file/1", "lib/x.ex", "file_read")
        |> Map.put("arg", %{"path" => Path.join(proj, "deps/dep/include/n_config.hrl")})

      r = rebar_report(proj, "dep", %{"dep" => child([])})
      r = %{r | events: [header | r.events]}

      # N's verified tarball lists the header, so P's read of it is readable.
      home = Path.join(Path.dirname(proj), "hex-#{System.unique_integer([:positive])}")

      {"dep", release} =
        NccWorker.TracerFixtures.hex_release(home, "dep", ["src", "include", "c_src"], %{
          "rebar.config" => File.read!(Path.join(proj, "deps/dep/rebar.config")),
          "include/n_config.hrl" => "-define(WORD, 64).\n"
        })

      opts = [releases: %{"dep" => release}, hex_home: home, built_check: false]

      assert %{status: :skip, reason: reason} = Portability.judge(proj, "pkg", r, ["dep"], opts)
      assert reason == "closure dependency observed the host: dep (rebar3 build runs pre_hooks)"
    end

    # rebar3 installs a dependency's plugins under its own `_build` and
    # keeps their tarballs in its cache: a release the table does not pin
    # taints, and a named plugin not installed could not be judged.
    test "a dependency's reviewed plugin is held to the pinned releases", %{proj: proj} do
      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{plugins, [rebar3_ex_doc]}.\n")
      r = rebar_report(proj, "dep", %{"dep" => child([])})
      cache = Path.join(Path.dirname(proj), "rebar3-cache")
      opts = rebar_opts(proj, ["dep"]) ++ [rebar_cache: cache]

      assert %{status: :skip, reason: @cnj, observations: obs} = judge(proj, r, opts)
      assert "dep: rebar3 plugin rebar3_ex_doc is named but not installed" in obs["problems"]

      dir = Path.join(proj, "deps/dep/_build/default/plugins/rebar3_ex_doc")
      File.mkdir_p!(Path.join(dir, "ebin"))

      File.write!(
        Path.join(dir, "hex_metadata.config"),
        ~s({<<"name">>,<<"rebar3_ex_doc">>}.\n{<<"version">>,<<"0.3.99">>}.\n)
      )

      assert %{
               reason:
                 "closure dependency observed the host: dep (rebar3 build runs plugin " <>
                   "rebar3_ex_doc 0.3.99, a release not reviewed)",
               observations: obs
             } = judge(proj, r, opts)

      # The build records what it ran, so the portal can find it: each
      # release once, with the apps that ran it (review S5 R3).
      assert obs["rebar3_plugins"] == [
               %{
                 "name" => "rebar3_ex_doc",
                 "version" => "0.3.99",
                 "sha256" => nil,
                 "owners" => ["dep"]
               }
             ]
    end

    # S8 pilot (F382): a firmware target's trace compiles the run's `deps/`
    # renamed to `deps_<target>`, so the `prod` profile's absolute link to a
    # plugin names the old deps dir. `moved_deps:` (the dirs the trace's deps
    # dir was moved from) lets the check follow it to the dir that moved,
    # which it then judges as any: here a release the table does not pin.
    test "a plugin link into the deps dir the trace renamed is followed", %{proj: proj} do
      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{plugins, [rebar3_ex_doc]}.\n")
      r = rebar_report(proj, "dep", %{"dep" => child([])})
      cache = Path.join(Path.dirname(proj), "rebar3-cache")
      opts = rebar_opts(proj, ["dep"]) ++ [rebar_cache: cache]

      dir = Path.join(proj, "deps/dep/_build/default/plugins/rebar3_ex_doc")
      File.mkdir_p!(Path.join(dir, "ebin"))

      File.write!(
        Path.join(dir, "hex_metadata.config"),
        ~s({<<"name">>,<<"rebar3_ex_doc">>}.\n{<<"version">>,<<"0.3.99">>}.\n)
      )

      old = Path.join(proj, "deps_before")
      prod = Path.join(proj, "deps/dep/_build/prod/plugins")
      File.mkdir_p!(prod)

      File.ln_s!(
        Path.join(old, "dep/_build/default/plugins/rebar3_ex_doc"),
        Path.join(prod, "rebar3_ex_doc")
      )

      assert %{
               reason:
                 "closure dependency observed the host: dep (rebar3 build runs a plugin from " <>
                   "a dir it cannot judge (rebar3_ex_doc))"
             } = judge(proj, r, opts)

      assert %{
               reason:
                 "closure dependency observed the host: dep (rebar3 build runs plugin " <>
                   "rebar3_ex_doc 0.3.99, a release not reviewed)",
               observations: obs
             } = judge(proj, r, opts ++ [moved_deps: [old]])

      assert [%{"name" => "rebar3_ex_doc", "version" => "0.3.99"}] = obs["rebar3_plugins"]
    end

    # Review S5 R3: the record is never cut. More distinct plugin releases
    # than it holds refuse the build.
    test "a closure running more plugin releases than the record holds refuses", %{proj: proj} do
      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{erl_opts, []}.\n")
      r = rebar_report(proj, "dep", %{"dep" => child([])})
      cache = Path.join(Path.dirname(proj), "rebar3-cache")
      opts = rebar_opts(proj, ["dep"]) ++ [rebar_cache: cache]
      max = NccWorker.Portability.RebarPlugins.max_releases()

      for i <- 1..(max + 1) do
        dir = Path.join(proj, "deps/dep/_build/default/plugins/fx_p#{i}")
        File.mkdir_p!(dir)

        File.write!(
          Path.join(dir, "hex_metadata.config"),
          ~s({<<"name">>,<<"fx_p#{i}">>}.\n{<<"version">>,<<"1.0.0">>}.\n)
        )
      end

      assert %{status: :skip, reason: reason, observations: obs} = judge(proj, r, opts)
      assert reason == "rebar3 build runs more than #{max} plugin releases"
      assert length(obs["rebar3_plugins"]) == max + 1
    end

    test "a dependency whose mix.rebar.config is missing could not be judged", %{proj: proj} do
      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{erl_opts, []}.\n")
      r = rebar_report(proj, "dep", %{"dep" => child([])})
      File.rm!(Path.join([proj, "_build/host/lib/dep/mix.rebar.config"]))

      assert %{status: :skip, reason: @cnj, observations: obs} =
               judge(proj, r, rebar_opts(proj, ["dep"]))

      assert obs["taint"] == %{}
    end

    # Review S5 S2: what rebar3 evaluates itself is read from the verified
    # tarball too, a dependency's and the package's own.
    test "an .app.src.script or a computed vsn in the tarball refuses", %{proj: proj} do
      r = rebar_report(proj, "dep", %{"dep" => child([])})
      config = %{"rebar.config" => "{erl_opts, []}.\n"}

      script = %{
        "src/dep.app.src.script" => ~s|CONFIG ++ [{env, [{arch, os:cmd("uname -m")}]}].\n|
      }

      opts = rebar_opts(proj, ["dep"], %{"dep" => Map.merge(config, script)})

      assert %{
               status: :skip,
               reason:
                 "closure dependency observed the host: dep (rebar3 build evaluates an .app.src.script)"
             } = judge(proj, r, opts)

      cmd = %{"src/dep.app.src" => ~s|{application, dep, [{vsn, {cmd, "uname -m"}}]}.\n|}
      opts = rebar_opts(proj, ["dep"], %{"dep" => Map.merge(config, cmd)})

      assert %{
               reason:
                 "closure dependency observed the host: dep (rebar3 build computes its .app.src vsn)"
             } = judge(proj, r, opts)

      plain = %{"src/dep.app.src" => ~s|{application, dep, [{vsn, "0.1.0"}]}.\n|}
      opts = rebar_opts(proj, ["dep"], %{"dep" => Map.merge(config, plain)})
      assert %{status: :pass, observations: %{"taint" => taint}} = judge(proj, r, opts)
      assert taint == %{}
    end

    test "rebar.config is read from the verified tarball, not deps/ after the build",
         %{proj: proj} do
      hook = ~s({erl_opts, []}.\n{pre_hooks, [{compile, "sh evil.sh"}]}.\n)
      # On disk the hook removed itself; the tarball still has it.
      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{erl_opts, []}.\n")
      r = rebar_report(proj, "dep", %{"dep" => child([])})
      opts = rebar_opts(proj, ["dep"], %{"dep" => %{"rebar.config" => hook}})

      assert %{reason: "closure dependency observed the host: dep (rebar3 build runs pre_hooks)"} =
               judge(proj, r, opts)

      # A script in the tarball is judged by what its evaluation read (the
      # trace, outside every window) and by the mix.rebar.config Mix wrote
      # from its result: a clean one does not taint.
      opts =
        rebar_opts(proj, ["dep"], %{
          "dep" => %{"rebar.config" => "{erl_opts, []}.\n", "rebar.config.script" => "CONFIG.\n"}
        })

      assert %{status: :pass, observations: %{"taint" => taint}} = judge(proj, r, opts)
      assert taint == %{}

      # A hook the script added is in the mix.rebar.config Mix wrote from it.
      File.write!(
        Path.join(proj, "_build/host/lib/dep/mix.rebar.config"),
        ~s({erl_opts,[]}.\n{pre_hooks,[{compile,"sh evil.sh"}]}.\n)
      )

      assert %{reason: "closure dependency observed the host: dep (rebar3 build runs pre_hooks)"} =
               judge(proj, r, opts)

      File.write!(Path.join(proj, "_build/host/lib/dep/mix.rebar.config"), "{erl_opts, []}.\n")

      # No verified tarball: could not be judged, never a pass.
      assert %{status: :skip, reason: @cnj, observations: obs} =
               judge(proj, r, releases: %{}, hex_home: nil)

      assert obs["taint"] == %{}
      assert Enum.any?(obs["problems"], &(&1 =~ "verified Hex tarball"))

      unverified =
        put_in(
          rebar_opts(proj, ["dep"]),
          [:releases, "dep", :checksum],
          String.duplicate("0", 64)
        )

      assert %{status: :skip, reason: @cnj} = judge(proj, r, unverified)
    end

    test "a rebar3 parent's overrides that Mix applies are read from its tarball", %{proj: proj} do
      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{erl_opts, []}.\n")
      r = rebar_report(proj, "dep", %{"dep" => child([])})

      # `other` (rebar3) lists dep as its child and overrides its hooks.
      deps =
        for d <- r.closure["deps"] do
          case d["app"] do
            "other" -> %{d | "manager" => "rebar3", "children" => ["dep"]}
            _ -> d
          end
        end

      r = %{
        r
        | closure: %{r.closure | "deps" => deps},
          children: Map.put(r.children, "other", child([]))
      }

      File.write!(Path.join([proj, "_build/host/lib/other/mix.rebar.config"]), "")
      parent = ~s({overrides, [{override, dep, [{pre_hooks, [{compile, "make"}]}]}]}.\n)

      opts = rebar_opts(proj, ["dep", "other"], %{"other" => %{"rebar.config" => parent}})

      assert %{reason: "closure dependency observed the host: dep (rebar3 build runs pre_hooks)"} =
               judge(proj, r, opts)

      clean =
        rebar_opts(proj, ["dep", "other"], %{"other" => %{"rebar.config" => "{erl_opts, []}.\n"}})

      assert %{status: :pass} = judge(proj, r, clean)

      # A parent without a verified tarball: could not be judged.
      assert %{status: :skip, reason: @cnj} = judge(proj, r, rebar_opts(proj, ["dep"]))
    end

    # A scripted rebar3 parent (idna, shotgun, erlware_commons, coveralls):
    # Mix evaluates its script under the trace and writes the result, the
    # overrides it hands its children included, to its own mix.rebar.config.
    test "a scripted rebar3 parent's overrides are read from its mix.rebar.config",
         %{proj: proj} do
      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{erl_opts, []}.\n")
      r = rebar_report(proj, "dep", %{"dep" => child([])})

      deps =
        for d <- r.closure["deps"] do
          case d["app"] do
            "other" -> %{d | "manager" => "rebar3", "children" => ["dep"]}
            _ -> d
          end
        end

      r = %{
        r
        | closure: %{r.closure | "deps" => deps},
          children: Map.put(r.children, "other", child([]))
      }

      parent_mix = Path.join([proj, "_build/host/lib/other/mix.rebar.config"])

      tarball = %{
        "other" => %{
          "rebar.config" => "{erl_opts, []}.\n",
          "rebar.config.script" => "CONFIG.\n"
        }
      }

      opts = rebar_opts(proj, ["dep", "other"], tarball)

      File.write!(parent_mix, "{erl_opts,[]}.\n{overrides,[{override,dep,[{erl_opts,[]}]}]}.\n")
      assert %{status: :pass} = judge(proj, r, opts)

      # What the script evaluated to is held to the override rules.
      File.write!(
        parent_mix,
        ~s({erl_opts,[]}.\n{overrides,[{override,dep,[{pre_hooks,[{compile,"make"}]}]}]}.\n)
      )

      assert %{reason: "closure dependency observed the host: dep (rebar3 build runs pre_hooks)"} =
               judge(proj, r, opts)

      # Without the file the overrides are unknown: could not be judged.
      File.rm!(parent_mix)
      assert %{status: :skip, reason: @cnj, observations: obs} = judge(proj, r, opts)
      assert Enum.any?(obs["problems"], &(&1 =~ "mix.rebar.config"))
    end

    test "a dependency with telemetry's real rebar.config is not tainted", %{proj: proj} do
      config =
        File.read!(Path.join([__DIR__, "../../fixtures/rebar/telemetry-1.4.2.rebar.config"]))

      File.write!(Path.join([proj, "deps/dep/rebar.config"]), config)

      assert %{status: :pass, observations: obs} =
               rjudge(proj, "dep", %{"dep" => child([])})

      assert obs["taint"] == %{}
    end

    test "a dependency compile that returned an error could not be judged", %{proj: proj} do
      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{erl_opts, []}.\n")
      beam!(proj, "dep", "JudgeRebarE1")

      traced =
        child([], %{
          compiles: [
            compiled_line(proj, "dep", "Elixir.JudgeRebarE1"),
            %{"result" => "error", "module" => nil}
          ]
        })

      assert %{status: :skip, reason: @cnj, observations: obs} =
               rjudge(proj, "dep", %{"dep" => traced})

      assert obs["taint"] == %{}
      assert Enum.any?(obs["problems"], &(&1 =~ "rebar3 compile returned an error"))
    end

    test "a rebar3 dependency with an empty ebin and no child trace could not be judged",
         %{proj: proj} do
      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{erl_opts, []}.\n")
      assert %{status: :skip, reason: @cnj} = rjudge(proj, "dep", %{})
    end

    test "one lost last compile return is recorded in trace_stats, not taint",
         %{proj: proj} do
      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{erl_opts, []}.\n")
      for m <- ["JudgeRebarG1", "JudgeRebarG2"], do: beam!(proj, "dep", m)
      traced = child([], %{compiles: [compiled_line(proj, "dep", "Elixir.JudgeRebarG1")]})

      assert %{status: :pass, observations: obs} =
               rjudge(proj, "dep", %{"dep" => traced})

      assert obs["trace_stats"]["rebar3_untraced_last"] == %{"dep" => "Elixir.JudgeRebarG2"}
      assert obs["taint"] == %{}
    end
  end

  describe "a reviewed rebar3 compile hook (quic's build_nif.sh)" do
    # webtransport 0.5.8: its only taint was quic's compile hook,
    # `{"(linux|darwin|solaris)", compile, "sh c_src/build_nif.sh"}`. The
    # real quic 2.7.0 rebar.config and script, as its Hex tarball has them.
    @quic Path.expand("../../fixtures/quic-2.7.0", __DIR__)
    @quic_sha "e92786641bbfba08e0640db6eca95247b468bd923729d0e5b199e9a278b2ab0b"

    setup %{proj: proj} do
      config = File.read!(Path.join(@quic, "rebar.config"))
      script = File.read!(Path.join(@quic, "c_src/build_nif.sh"))
      File.mkdir_p!(Path.join([proj, "deps/quic/c_src"]))
      File.mkdir_p!(Path.join([proj, "_build/host/lib/quic/ebin"]))
      File.write!(Path.join([proj, "deps/quic/rebar.config"]), config)
      File.write!(Path.join([proj, "deps/quic/c_src/build_nif.sh"]), script)
      File.write!(Path.join([proj, "_build/host/lib/quic/mix.rebar.config"]), config)
      %{config: config, script: script}
    end

    defp quic_report(proj, events \\ []) do
      r = report(proj, %{children: %{"quic" => child([])}, events: events})

      deps =
        Enum.map(r.closure["deps"], fn
          %{"app" => "pkg"} = d -> %{d | "children" => ["dep", "quic"]}
          d -> d
        end)

      %{
        r
        | closure: %{r.closure | "deps" => [dep(proj, "quic", [], "rebar3") | deps]},
          windows: [window("quic", 1, 9) | r.windows],
          sentinels: [%{app: "quic", ts: 2, integrity_ok: true} | r.sentinels]
      }
    end

    defp quic_opts(proj, contents, hook_scripts) do
      home = Path.join(Path.dirname(proj), "hex-#{System.unique_integer([:positive])}")

      releases =
        Map.new(["dep", "pkg", "other", "quic"], fn app ->
          files = if app == "quic", do: contents, else: %{"README" => ""}
          NccWorker.TracerFixtures.hex_release(home, app, ["src"], files)
        end)

      [releases: releases, hex_home: home, hook_scripts: hook_scripts]
    end

    @taint "closure dependency observed the host: quic (rebar3 build runs pre_hooks)"

    test "passes only with the reviewed script in the tarball and on disk before the compile",
         %{proj: proj, config: config, script: script} do
      contents = %{"rebar.config" => config, "c_src/build_nif.sh" => script}
      r = quic_report(proj)

      assert %{status: :pass, observations: %{"taint" => taint}} =
               judge(proj, r, quic_opts(proj, contents, %{"quic" => @quic_sha}))

      assert taint == %{}

      # No disk digest (run/3 takes none when QUIC_BUILD_NIF is set): taint.
      assert %{reason: @taint} = judge(proj, r, quic_opts(proj, contents, %{}))

      # A disk copy with another digest: taint.
      other = String.duplicate("0", 64)
      assert %{reason: @taint} = judge(proj, r, quic_opts(proj, contents, %{"quic" => other}))

      # A tarball whose script is not the reviewed one: taint.
      edited = %{contents | "c_src/build_nif.sh" => script <> "touch /tmp/x\n"}
      assert %{reason: @taint} = judge(proj, r, quic_opts(proj, edited, %{"quic" => @quic_sha}))

      # A tarball without the script: taint.
      bare = Map.delete(contents, "c_src/build_nif.sh")
      assert %{reason: @taint} = judge(proj, r, quic_opts(proj, bare, %{"quic" => @quic_sha}))
    end

    test "a traced write of QUIC_BUILD_NIF keeps the hook counting",
         %{proj: proj, config: config, script: script} do
      contents = %{"rebar.config" => config, "c_src/build_nif.sh" => script}

      write =
        Map.merge(event(31, "os:putenv/2", Path.join([proj, "deps/pkg/mix.exs"]), "env_write"), %{
          "arg" => %{"name" => "QUIC_BUILD_NIF", "value" => "1"}
        })

      r = quic_report(proj, [write])

      assert %{reason: @taint} =
               judge(proj, r, quic_opts(proj, contents, %{"quic" => @quic_sha}))
    end

    test "another hook, arch or command beside the reviewed one still counts",
         %{proj: proj, script: script} do
      for config <- [
            ~s'{pre_hooks, [{"(linux|darwin|solaris)", compile, "sh c_src/build_nif.sh"}, {compile, "make"}]}.\n',
            ~s'{pre_hooks, [{"linux", compile, "sh c_src/build_nif.sh"}]}.\n',
            ~s'{pre_hooks, [{"(linux|darwin|solaris)", erlc_compile, "sh c_src/build_nif.sh"}]}.\n',
            ~s'{pre_hooks, [{"(linux|darwin|solaris)", compile, "sh c_src/build_nif.sh build"}]}.\n',
            ~s'{overrides, [{override, quic, [{pre_hooks, [{"(linux|darwin|solaris)", compile, "sh c_src/build_nif.sh"}]}]}]}.\n'
          ] do
        File.write!(Path.join([proj, "_build/host/lib/quic/mix.rebar.config"]), config)
        contents = %{"rebar.config" => config, "c_src/build_nif.sh" => script}

        assert %{status: :skip, observations: %{"taint" => %{"quic" => _}}} =
                 judge(proj, quic_report(proj), quic_opts(proj, contents, %{"quic" => @quic_sha})),
               config
      end
    end

    test "run/3's disk digest: only with QUIC_BUILD_NIF unset", %{proj: proj} do
      assert Portability.hook_scripts(proj, []) == %{"quic" => @quic_sha}
      assert Portability.hook_scripts(proj, [{"QUIC_BUILD_NIF", nil}]) == %{"quic" => @quic_sha}
      assert Portability.hook_scripts(proj, [{"QUIC_BUILD_NIF", "1"}]) == %{}
      assert Portability.hook_scripts(proj, [{"QUIC_BUILD_NIF", ""}]) == %{}

      File.rm!(Path.join([proj, "deps/quic/c_src/build_nif.sh"]))

      File.ln_s!(
        Path.join(@quic, "c_src/build_nif.sh"),
        Path.join([proj, "deps/quic/c_src/build_nif.sh"])
      )

      assert Portability.hook_scripts(proj, []) == %{}
    end

    test "run/3's disk digest reads the deps dir the compile's env names", %{proj: proj} do
      target_deps = Path.join(proj, "deps_rpi4")
      File.rename!(Path.join(proj, "deps"), target_deps)

      assert Portability.hook_scripts(proj, []) == %{}

      assert Portability.hook_scripts(proj, [{"MIX_DEPS_PATH", target_deps}]) ==
               %{"quic" => @quic_sha}

      assert Portability.hook_scripts(proj, [{"MIX_DEPS_PATH", "deps_rpi4"}]) ==
               %{"quic" => @quic_sha}
    end
  end

  describe "Rebar" do
    defp write(dir, name, files) do
      d = Path.join(dir, name)
      File.mkdir_p!(d)
      Enum.each(files, fn {f, body} -> File.write!(Path.join(d, f), body) end)
      d
    end

    test "static rules", %{tmp_dir: dir} do
      assert :ok = Rebar.check(write(dir, "none", %{}))

      assert :ok =
               Rebar.check(
                 write(dir, "clean", %{
                   "rebar.config" => "{erl_opts, [debug_info]}.\n{pre_hooks, []}.\n"
                 })
               )

      for {name, config, reason} <- [
            {"hooks", ~s({pre_hooks, [{compile, "make"}]}.\n), "rebar3 build runs pre_hooks"},
            {"post", ~s({post_hooks, [{compile, "make"}]}.\n), "rebar3 build runs post_hooks"},
            {"prov", "{provider_hooks, [{pre, [{compile, {pc, compile}}]}]}.\n",
             "rebar3 build runs provider_hooks"},
            {"plugins", "{plugins, [pc]}.\n", "rebar3 build runs plugins"},
            {"hex_and_other", "{plugins, [rebar3_hex, pc]}.\n", "rebar3 build runs plugins"},
            {"reviewed_git",
             ~s|{plugins, [{rebar3_ex_doc, {git, "https://x/y.git", {branch, "main"}}}]}.\n|,
             "rebar3 build runs plugins"},
            {"reviewed_pkg", ~s|{plugins, [{rebar3_lint, "~> 5.0", {pkg, other}}]}.\n|,
             "rebar3 build runs plugins"},
            # A separate Hex package from covertool, never reviewed.
            {"rebar_covertool", "{plugins, [rebar_covertool]}.\n", "rebar3 build runs plugins"},
            {"compiler_plugin", ~s|{plugins, [{rebar3_clojerl, "0.8.8"}]}.\n|,
             "rebar3 build runs plugins"},
            {"prov_pre_escriptize", "{provider_hooks, [{pre, [{compile, escriptize}]}]}.\n",
             "rebar3 build runs provider_hooks"},
            {"prov_other_ns", "{provider_hooks, [{post, [{compile, {x, escriptize}}]}]}.\n",
             "rebar3 build runs provider_hooks"},
            {"default_ns_hook", ~s({pre_hooks, [{{default, compile}, "make"}]}.\n),
             "rebar3 build runs pre_hooks"},
            # No hook that `bare compile` can reach runs (review S5 R1): rebar3
            # runs `escriptize` (cuttlefish's provider hook) and its own shell
            # hooks inside `bare compile`, untraced. Nor do S5's other
            # exceptions stand: `mkdir -p ebin` (pbkdf2) and a namespaced
            # command (dbi) refuse as on main.
            {"prov_escriptize",
             "{provider_hooks, [{post, [{compile, {default, escriptize}}]}]}.\n",
             "rebar3 build runs provider_hooks"},
            {"prov_escriptize_bare", "{provider_hooks, [{post, [{compile, escriptize}]}]}.\n",
             "rebar3 build runs provider_hooks"},
            {"escriptize_post_hook",
             ~s|{escript_main_app, n}.\n{post_hooks, [{escriptize, "sh tools/gen.sh"}]}.\n|,
             "rebar3 build runs post_hooks"},
            {"escriptize_pre_hook", ~s|{pre_hooks, [{{default, escriptize}, "x"}]}.\n|,
             "rebar3 build runs pre_hooks"},
            {"escriptize_arch_hook", ~s|{post_hooks, [{"linux", escriptize, "x"}]}.\n|,
             "rebar3 build runs post_hooks"},
            {"escriptize_provider_hook", "{provider_hooks, [{pre, [{escriptize, edoc}]}]}.\n",
             "rebar3 build runs provider_hooks"},
            {"escriptize_override",
             ~s|{overrides, [{override, x, [{post_hooks, [{escriptize, "x"}]}]}]}.\n|,
             "rebar3 build runs post_hooks"},
            {"escriptize_profile",
             ~s|{profiles, [{prod, [{post_hooks, [{escriptize, "x"}]}]}]}.\n|,
             "rebar3 build runs post_hooks"},
            {"mkdir_ebin_hook", ~s|{pre_hooks, [{compile, "mkdir -p ebin"}]}.\n|,
             "rebar3 build runs pre_hooks"},
            {"ns_hook", ~s|{pre_hooks, [{{hex, publish}, "./update_vsn_mix.sh"}]}.\n|,
             "rebar3 build runs pre_hooks"},
            {"ns_arch_hook", ~s|{post_hooks, [{"linux", {hex, publish}, "x"}]}.\n|,
             "rebar3 build runs post_hooks"},
            {"mkdir_other", ~s|{pre_hooks, [{compile, "mkdir -p ebin && make"}]}.\n|,
             "rebar3 build runs pre_hooks"},
            {"mkdir_priv", ~s|{pre_hooks, [{compile, "mkdir -p priv"}]}.\n|,
             "rebar3 build runs pre_hooks"},
            {"mkdir_override",
             ~s|{overrides, [{override, x, [{pre_hooks, [{compile, "mkdir -p ebin"}]}]}]}.\n|,
             "rebar3 build runs pre_hooks"},
            {"hex_git", ~s|{plugins, [{rebar3_hex, {git, "https://x/y.git", {tag, "1"}}}]}.\n|,
             "rebar3 build runs plugins"},
            {"hex_pkg", "{plugins, [{rebar3_hex, {pkg, evil}}]}.\n", "rebar3 build runs plugins"},
            {"hex_vsn_pkg", ~s|{plugins, [{rebar3_hex, "7.1.0", {pkg, rebar3_hex}}]}.\n|,
             "rebar3 build runs plugins"},
            {"hex_bad_req", ~s|{plugins, [{rebar3_hex, "latest"}]}.\n|,
             "rebar3 build runs plugins"},
            {"hex_not_list", "{plugins, rebar3_hex}.\n", "rebar3 build runs plugins"},
            {"hex_string_name", ~s|{plugins, ["rebar3_hex"]}.\n|, "rebar3 build runs plugins"},
            {"pd", ~s({erl_opts, [{platform_define, 'win32', 'WIN'}]}.\n),
             "rebar3 build uses platform_define"},
            {"profile", ~s({profiles, [{prod, [{pre_hooks, [{compile, "make"}]}]}]}.\n),
             "rebar3 build runs pre_hooks"},
            {"profile_pd",
             ~s({profiles, [{prod, [{erl_opts, [{platform_define, 42, 'X'}]}]}]}.\n),
             "rebar3 build uses platform_define"},
            {"profile_plugins", "{profiles, [{prod, [{plugins, [pc]}]}]}.\n",
             "rebar3 build runs plugins"},
            {"default_profile", ~s({profiles, [{default, [{post_hooks, [{compile, "x"}]}]}]}.\n),
             "rebar3 build runs post_hooks"},
            {"override", ~s({overrides, [{add, [{pre_hooks, [{compile, "make"}]}]}]}.\n),
             "rebar3 build runs pre_hooks"},
            {"prod_override",
             ~s({profiles, [{prod, [{overrides, [{override, [{pre_hooks, [{compile, "x"}]}]}]}]}]}.\n),
             "rebar3 build runs pre_hooks"},
            {"default_override_plugins",
             "{profiles, [{default, [{overrides, [{add, x, [{plugins, [pc]}]}]}]}]}.\n",
             "rebar3 build runs plugins"},
            {"erlc_hook", ~s({pre_hooks, [{erlc_compile, "make"}]}.\n),
             "rebar3 build runs pre_hooks"},
            {"app_hook", ~s({post_hooks, [{"linux", app_compile, "make"}]}.\n),
             "rebar3 build runs post_hooks"},
            {"mixed_hooks", ~s({pre_hooks, [{clean, "rm x"}, {compile, "make"}]}.\n),
             "rebar3 build runs pre_hooks"},
            {"odd_hook", ~s({pre_hooks, [{compile}]}.\n), "rebar3 build runs pre_hooks"},
            {"bare_hook", "{pre_hooks, [clean]}.\n", "rebar3 build runs pre_hooks"},
            {"string_cmd", ~s({pre_hooks, [{"clean", "rm x"}]}.\n),
             "rebar3 build runs pre_hooks"},
            {"not_list_hooks", ~s({pre_hooks, {clean, "rm x"}}.\n),
             "rebar3 build runs pre_hooks"},
            {"prov_erlc", "{provider_hooks, [{post, [{erlc_compile, {x, y}}]}]}.\n",
             "rebar3 build runs provider_hooks"},
            {"prov_odd", "{provider_hooks, [{pre, compile}]}.\n",
             "rebar3 build runs provider_hooks"},
            {"prov_bare", "{provider_hooks, [{pre, [compile]}]}.\n",
             "rebar3 build runs provider_hooks"},
            {"prov_type", "{provider_hooks, [{around, [{clean, {x, y}}]}]}.\n",
             "rebar3 build runs provider_hooks"},
            {"override_compile_hook",
             ~s|{overrides, [{override, x, [{post_hooks, [{"(linux)", compile, "make"}]}]}]}.\n|,
             "rebar3 build runs post_hooks"},
            {"garbled", "{erl_opts, [\n", "rebar3 build config unreadable"},
            {"macro", "{erl_opts, [?X]}.\n", "rebar3 build config unreadable"}
          ] do
        assert {:refuse, ^reason} = Rebar.check(write(dir, name, %{"rebar.config" => config})),
               name
      end

      # A script without the mix.rebar.config Mix wrote from it: its result
      # is unknown.
      assert {:refuse, "rebar3 build evaluates rebar.config.script"} =
               Rebar.check(
                 write(dir, "script", %{
                   "rebar.config" => "{erl_opts, []}.\n",
                   "rebar.config.script" => "CONFIG.\n"
                 })
               )

      # Not run when Mix compiles the dependency (`REBAR_PROFILE=prod`,
      # `REBAR_SKIP_PROJECT_PLUGINS=true`, `project_plugins` dropped from
      # mix.rebar.config): project plugins, and anything in another profile.
      for {name, config} <- [
            {"pplugins", "{project_plugins, [rebar3_hex]}.\n"},
            {"test_hooks", ~s({profiles, [{test, [{pre_hooks, [{compile, "make"}]}]}]}.\n)},
            {"test_plugins",
             "{profiles, [{test, [{plugins, [covertool]}]}, {docs, [{plugins, [x]}]}]}.\n"},
            {"test_pd", ~s({profiles, [{test, [{erl_opts, [{platform_define, "x", 'X'}]}]}]}.\n)},
            {"dep_named_plugins", ~s({deps, [{plugins, "1.0.0"}, pre_hooks]}.\n)},
            # rebar3_hex from Hex: its init/1 only registers `hex` providers
            # (mimerl, cowboy_telemetry, verl 0.1.0).
            {"hex_plugin", "{plugins, [rebar3_hex]}.\n"},
            {"hex_plugin_req", ~s|{plugins, [{rebar3_hex, "~> 7.0"}]}.\n|},
            {"hex_plugin_bin", ~s|{plugins, [{rebar3_hex, <<"7.1.0">>}]}.\n|},
            {"hex_plugin_prod", "{profiles, [{prod, [{plugins, [rebar3_hex]}]}]}.\n"},
            {"hex_plugin_override", "{overrides, [{override, x, [{plugins, [rebar3_hex]}]}]}.\n"},
            # The reviewed plugins: every release's init/1 registers providers
            # alone (otel_http, aws_credentials, spectra, pipes, cets).
            {"ex_doc_plugin", "{plugins, [rebar3_ex_doc]}.\n"},
            {"lint_plugin_req", ~s|{plugins, [{rebar3_lint, "~> 5.0"}]}.\n|},
            {"proper_plugin_exact", ~s|{plugins, [{rebar3_proper, "0.11.1"}]}.\n|},
            {"coverage_plugins", "{plugins, [coveralls, covertool, rebar3_hex]}.\n"},
            {"reviewed_prod", "{profiles, [{prod, [{plugins, [rebar3_ex_doc]}]}]}.\n"},
            # Hooks on a command `rebar3 bare compile` never runs (hackney,
            # yamerl, erlfmt, covertool: `clean`).
            {"clean_hook", ~s({pre_hooks, [{clean, "rm -rf *~ */*~"}]}.\n)},
            {"arch_clean_hook", ~s|{post_hooks, [{"(linux\|darwin)", clean, "make clean"}]}.\n|},
            {"eunit_hook", ~s({pre_hooks, [{eunit, "x"}, {ct, "y"}]}.\n)},
            {"prov_clean", "{provider_hooks, [{pre, [{clean, {pc, clean}}]}, {post, []}]}.\n"},
            {"override_clean_hook",
             ~s({overrides, [{override, x, [{pre_hooks, [{clean, "rm x"}]}]}]}.\n)},
            {"test_override",
             ~s({profiles, [{test, [{overrides, [{override, [{pre_hooks, [{compile, "x"}]}]}]}]}]}.\n)}
          ] do
        assert :ok = Rebar.check(write(dir, name, %{"rebar.config" => config})), name
      end

      # A natively built app's shell compile hooks refuse like any other's:
      # rebar3 runs them untraced, and nothing checks what they wrote
      # (crc32cer's `make nif`). Nothing in `sources` lets them through.
      native = fn config ->
        Rebar.check_sources(%{config: config, script?: false, native?: true}, [], nil)
      end

      crc = ~s'{pre_hooks, [{"(linux|darwin|solaris|freebsd)", compile, "make nif"}]}.\n'
      assert {:refuse, "rebar3 build runs pre_hooks"} = native.(crc)

      assert {:refuse, "rebar3 build runs post_hooks"} =
               native.(~s({post_hooks, [{compile, "make -C c_src"}]}.\n))

      assert {:refuse, "rebar3 build runs provider_hooks"} =
               native.("{provider_hooks, [{pre, [{compile, {pc, compile}}]}]}.\n")

      # No atom is created from the config.
      atom = "ncc_rebar_never_an_atom_#{System.unique_integer([:positive])}"
      assert :ok = Rebar.check(write(dir, "atom", %{"rebar.config" => "{#{atom}, []}.\n"}))
      assert_raise ArgumentError, fn -> String.to_existing_atom(atom) end
    end

    # Review S5 S2: rebar3 evaluates an app's `src/<app>.app.src.script`
    # and runs a `.app.src` `vsn` command (`git`, `{cmd, ...}`, `semver`)
    # itself, in its own VM, with only OTP and rebar3 on the stack: the
    # trace drops what it does. What they compute goes into the published
    # `.app`, so either refuses, and so does an `.app.src` the judge cannot
    # read (it cannot tell its `vsn`).
    @app_src_cases [
      {"script",
       %{"src/x.app.src.script" => ~s|CONFIG ++ [{env, [{arch, os:cmd("uname -m")}]}].\n|},
       "rebar3 build evaluates an .app.src.script"},
      # A src dir the config names (`src_dirs`, top level, in `erl_opts`,
      # a profile or an override, as a string or with options).
      {"src_dirs_script",
       %{
         "rebar.config" => ~s|{src_dirs, ["src", {"lib", [{recursive, true}]}]}.\n|,
         "lib/x.app.src.script" => "CONFIG.\n"
       }, "rebar3 build evaluates an .app.src.script"},
      {"erl_opts_src_dir",
       %{
         "rebar.config" => ~s|{erl_opts, [{src_dirs, ["src/sub"]}]}.\n|,
         "src/sub/x.app.src" => "{application, x, [{vsn, git}]}.\n"
       }, "rebar3 build computes its .app.src vsn"},
      {"override_src_dir",
       %{
         "rebar.config" => ~s|{overrides, [{override, x, [{src_dirs, [<<"gen">>]}]}]}.\n|,
         "gen/x.app.src.script" => "CONFIG.\n"
       }, "rebar3 build evaluates an .app.src.script"},
      # A `src_dirs` the rule cannot read: every dir counts (fail closed).
      {"odd_src_dirs",
       %{
         "rebar.config" => "{src_dirs, [src, 1]}.\n",
         "priv/templates/x.app.src" => "{application, {{name}}, [{vsn, \"git\"}]}.\n"
       }, "rebar3 build .app.src unreadable"},
      {"vsn_git", %{"src/x.app.src" => "{application, x, [{vsn, git}]}.\n"},
       "rebar3 build computes its .app.src vsn"},
      {"vsn_cmd", %{"src/x.app.src" => ~s|{application, x, [{vsn, {cmd, "uname -m"}}]}.\n|},
       "rebar3 build computes its .app.src vsn"},
      {"vsn_semver", %{"src/x.app.src" => "{application, x, [{vsn, semver}]}.\n"},
       "rebar3 build computes its .app.src vsn"},
      {"vsn_git_short", %{"src/x.app.src" => "{application, x, [{vsn, {git, short}}]}.\n"},
       "rebar3 build computes its .app.src vsn"},
      {"vsn_binary", %{"src/x.app.src" => ~s|{application, x, [{vsn, <<"1.0.0">>}]}.\n|},
       "rebar3 build computes its .app.src vsn"},
      {"vsn_twice", %{"src/x.app.src" => ~s|{application, x, [{vsn, "1.0.0"}, {vsn, git}]}.\n|},
       "rebar3 build computes its .app.src vsn"},
      {"vsn_missing", %{"src/x.app.src" => "{application, x, [{registered, []}]}.\n"},
       "rebar3 build computes its .app.src vsn"},
      {"fun_in_env",
       %{"src/x.app.src" => ~s|{application, x, [{vsn, "1.0.0"}, {env, [{f, fun m:f/0}]}]}.\n|},
       "rebar3 build .app.src unreadable"},
      {"not_an_app", %{"src/x.app.src" => "{vsn, \"1.0.0\"}.\n"},
       "rebar3 build .app.src unreadable"}
    ]

    # Review S5 F1: a `vsn` string that names a resource type is a directive
    # too (`rebar_utils:vcs_vsn_cmd/3`): "git" writes the enclosing repo's
    # `git describe`, "hg" and "pkg" fail the compile.
    @vsn_directive_cases (for directive <- ~w(git semver hg pkg git_subdir) do
                            app_src = ~s|{application, x, [{vsn, "#{directive}"}]}.\n|

                            {"vsn_string_" <> directive, %{"src/x.app.src" => app_src},
                             "rebar3 build computes its .app.src vsn"}
                          end)

    defp write_tree(dir, name, files) do
      d = Path.join(dir, name)

      for {f, body} <- files do
        File.mkdir_p!(Path.dirname(Path.join(d, f)))
        File.write!(Path.join(d, f), body)
      end

      d
    end

    test "an .app.src.script or a computed .app.src vsn refuses", %{tmp_dir: dir} do
      plain = %{"src/x.app.src" => ~s|{application, x, [{vsn, "1.0.0"}, {registered, []}]}.\n|}
      assert :ok = Rebar.check(write_tree(dir, "plain", plain))

      # A version that only contains a directive's name, or another case of
      # it, is plain.
      for {name, vsn} <- [{"git_suffix", "1.0.0-git"}, {"git_case", "Git"}, {"pkg_in", "pkg1"}] do
        files = %{"src/x.app.src" => ~s|{application, x, [{vsn, "#{vsn}"}]}.\n|}
        assert :ok = Rebar.check(write_tree(dir, name, files)), name
      end

      # rebar3 reads `<src dir>/*.app.src` only (`rebar_app_discover`): a
      # template under priv (rebar3_erllambda 1.1.4, atomvm_rebar3_plugin
      # 0.7.5, rebar3_rustler 0.1.1) or a file below a src dir is never
      # evaluated (review S5, concern 1).
      template = "{application, {{name}}, [{vsn, \"git\"}, {registered, []}]}.\n"

      for {name, files} <- [
            {"priv_template", Map.put(plain, "priv/templates/erllambda.app.src", template)},
            {"priv_src", Map.put(plain, "priv/src/atomvm_app.app.src", template)},
            {"below_src", Map.put(plain, "src/sub/x.app.src.script", "CONFIG.\n")}
          ] do
        assert :ok = Rebar.check(write_tree(dir, name, files)), name
        home = Path.join(dir, "hex-" <> name)
        {_app, release} = NccWorker.TracerFixtures.hex_release(home, "x", ["src"], files)
        tar = File.read!(Path.join([home, "packages/hexpm", "x-#{release.version}.tar"]))
        assert {:ok, sources} = Rebar.tarball_sources(tar), name
        assert :ok = Rebar.check_sources(sources, [], nil), name
      end

      for {name, files, reason} <- @app_src_cases ++ @vsn_directive_cases do
        # On disk (`check/2`) and from the verified tarball (`check_sources/3`).
        assert {:refuse, ^reason} = Rebar.check(write_tree(dir, name, files)), name

        home = Path.join(dir, "hex-" <> name)
        {_app, release} = NccWorker.TracerFixtures.hex_release(home, "x", ["src"], files)
        tar = File.read!(Path.join([home, "packages/hexpm", "x-#{release.version}.tar"]))
        assert {:ok, sources} = Rebar.tarball_sources(tar), name
        assert {:refuse, ^reason} = Rebar.check_sources(sources, [], nil), name
      end

      home = Path.join(dir, "hex-plain")
      {_app, release} = NccWorker.TracerFixtures.hex_release(home, "x", ["src"], plain)
      tar = File.read!(Path.join([home, "packages/hexpm", "x-#{release.version}.tar"]))
      assert {:ok, sources} = Rebar.tarball_sources(tar)
      assert :ok = Rebar.check_sources(sources, [], nil)
    end

    # The real files of the 2026-11-06 benchmark lock's releases, vendored
    # unchanged from their Hex tarballs.
    test "telemetry 1.4.2's and mimerl 1.5.0's real rebar.config do not taint", %{tmp_dir: dir} do
      for name <- ["telemetry-1.4.2", "mimerl-1.5.0"] do
        config = File.read!(Path.join([__DIR__, "../../fixtures/rebar", name <> ".rebar.config"]))
        assert :ok = Rebar.check(write(dir, name, %{"rebar.config" => config})), name
      end
    end

    test "hackney 4.9.1's real rebar.config reads (erl_scan escapes) and records R14",
         %{tmp_dir: dir} do
      config =
        File.read!(Path.join([__DIR__, "../../fixtures/rebar/hackney-4.9.1.rebar.config"]))

      # A top-level `{pre_hooks, [{clean, "rm -rf ..."}]}` never runs under
      # `rebar3 bare compile`; its unanchored "R14" platform_define is a
      # compile input (no OTP since 17 has an `R` in its version), and the
      # four the OTP major decides are not.
      assert {:inputs, [%{"kind" => "platform_define", "regex" => "R14", "matched" => false}]} =
               Rebar.check(write(dir, "hackney", %{"rebar.config" => config}))

      on_compile =
        String.replace(
          config,
          ~s({pre_hooks, [{clean, "rm -rf *~ */*~ */*.xfm test/*.beam"}]}.),
          ~s({pre_hooks, [{compile, "rm -rf *~ */*~ */*.xfm test/*.beam"}]}.)
        )

      assert {:refuse, "rebar3 build runs pre_hooks"} =
               Rebar.check(write(dir, "hackney_hook", %{"rebar.config" => on_compile}))

      # As a parent it hands its children no overrides (only its test
      # profile has any), so they are not refused through it.
      child_sources = %{config: "{erl_opts, []}.\n", script?: false}

      assert :ok =
               Rebar.check_sources(child_sources, [%{config: config, script?: false}], nil)
    end

    test "the mix.rebar.config Mix hands rebar3 is checked too", %{tmp_dir: dir} do
      dest = write(dir, "dest", %{"rebar.config" => "{erl_opts, []}.\n"})
      build = write(dir, "build", %{"mix.rebar.config" => "{erl_opts,[]}.\n"})
      mix_config = Path.join(build, "mix.rebar.config")
      assert :ok = Rebar.check(dest, mix_config)

      # A parent's override that Mix applied adds a hook only there.
      File.write!(mix_config, ~s({erl_opts,[]}.\n{pre_hooks,[{compile,"make"}]}.\n))
      assert {:refuse, "rebar3 build runs pre_hooks"} = Rebar.check(dest, mix_config)

      File.rm!(mix_config)
      assert {:unjudged, "rebar3 mix.rebar.config missing"} = Rebar.check(dest, mix_config)
    end

    # Mix evaluates a dependency's rebar.config.script in its own VM, under
    # the trace (outside every window), and writes the result to
    # mix.rebar.config, the only config rebar3 reads: the script is judged
    # by what it read and by that result, not refused for existing.
    test "a rebar.config.script is judged by the mix.rebar.config Mix wrote from it",
         %{tmp_dir: dir} do
      script = """
      case os:getenv("CI") of "true" -> [{plugins, [x]} | CONFIG]; _ -> CONFIG end.
      """

      dest =
        write(dir, "dest", %{
          "rebar.config" => "{erl_opts, []}.\n",
          "rebar.config.script" => script
        })

      build = write(dir, "build", %{"mix.rebar.config" => "{erl_opts,[]}.\n"})
      mix_config = Path.join(build, "mix.rebar.config")
      assert :ok = Rebar.check(dest, mix_config)

      # What the script added is in its result.
      File.write!(mix_config, "{plugins,[x]}.\n{erl_opts,[]}.\n")
      assert {:refuse, "rebar3 build runs plugins"} = Rebar.check(dest, mix_config)

      File.write!(mix_config, ~s({erl_opts,[{platform_define,"linux",'L'}]}.\n))

      assert {:inputs, [%{"kind" => "platform_define", "regex" => "linux"}]} =
               Rebar.check(dest, mix_config)

      File.write!(mix_config, ~s({erl_opts,[{platform_define,linux,'L'}]}.\n))
      assert {:refuse, "rebar3 build uses platform_define"} = Rebar.check(dest, mix_config)

      File.rm!(mix_config)
      assert {:unjudged, "rebar3 mix.rebar.config missing"} = Rebar.check(dest, mix_config)

      # The tarball's own rebar.config is still held to the rules too.
      hooked =
        write(dir, "hooked", %{
          "rebar.config" => ~s({pre_hooks, [{compile, "make"}]}.\n),
          "rebar.config.script" => "CONFIG.\n"
        })

      File.write!(mix_config, "{erl_opts,[]}.\n")
      assert {:refuse, "rebar3 build runs pre_hooks"} = Rebar.check(hooked, mix_config)

      # A parent's script without its evaluated config leaves the overrides
      # it hands down unknown.
      assert {:unjudged, "a rebar3 parent evaluates rebar.config.script"} =
               Rebar.check_sources(
                 %{config: "{erl_opts, []}.\n", script?: false},
                 [%{config: "{erl_opts, []}.\n", script?: true}],
                 mix_config
               )
    end

    test "a scripted parent's overrides are its evaluated mix.rebar.config's", %{tmp_dir: dir} do
      own = %{config: "{erl_opts, []}.\n", script?: false}
      build = write(dir, "parent_build", %{})
      parent_mix = Path.join(build, "mix.rebar.config")
      parent = %{config: "{erl_opts, []}.\n", script?: true, mix_config: parent_mix}

      File.write!(parent_mix, "{erl_opts,[]}.\n{deps,[{x,\"1.0.0\"}]}.\n")
      assert :ok = Rebar.check_sources(own, [parent], nil)

      File.write!(
        parent_mix,
        ~s({erl_opts,[]}.\n{overrides,[{override,[{post_hooks,[{compile,"make"}]}]}]}.\n)
      )

      assert {:refuse, "rebar3 build runs post_hooks"} = Rebar.check_sources(own, [parent], nil)

      # Only its top-level overrides reach the child: a hook of its own is
      # its own rule's business.
      File.write!(parent_mix, ~s({erl_opts,[]}.\n{pre_hooks,[{compile,"make"}]}.\n))
      assert :ok = Rebar.check_sources(own, [parent], nil)

      # The tarball's static overrides still count too (fail closed).
      static = ~s({overrides,[{override,[{plugins,[x]}]}]}.\n)

      assert {:refuse, "rebar3 build runs plugins"} =
               Rebar.check_sources(own, [%{parent | config: static}], nil)

      File.write!(parent_mix, "{overrides, [unterminated")

      assert {:unjudged, "a rebar3 parent's mix.rebar.config is unreadable"} =
               Rebar.check_sources(own, [parent], nil)

      File.rm!(parent_mix)

      assert {:unjudged, "a rebar3 parent's mix.rebar.config is missing"} =
               Rebar.check_sources(own, [parent], nil)

      assert {:unjudged, "rebar3 build dir missing"} =
               Rebar.check_sources(
                 own,
                 [%{parent | mix_config: {:unjudged, "rebar3 build dir missing"}}],
                 nil
               )
    end

    test "coverage needs a sentinel and a traced compile:file per beam", %{tmp_dir: dir} do
      ebin = Path.join(dir, "ebin")
      File.mkdir_p!(ebin)

      # An empty ebin with no child trace proves nothing.
      assert {:unjudged, "rebar3 built nothing and was not traced"} = Rebar.coverage(ebin, nil)
      assert :ok = Rebar.coverage(ebin, child([]))

      for m <- ["r3", "r4", "r5"], do: File.write!(Path.join(ebin, m <> ".beam"), "beam " <> m)

      # Each compile line carries the sha256 of the beam its compile wrote,
      # taken when it returned (review S5 R1).
      sha = fn m -> :sha256 |> :crypto.hash("beam " <> m) |> Base.encode16(case: :lower) end
      ok = fn m -> %{"result" => "ok", "module" => m, "beam_sha256" => sha.(m)} end
      c = child([], %{compiles: Enum.map(["r3", "r4", "r5"], ok)})

      assert :ok = Rebar.coverage(ebin, c)

      # A beam written over after its compile returned taints, whatever wrote it.
      File.write!(Path.join(ebin, "r4.beam"), "beam r4, overwritten")

      assert {:error, "rebar3 beam r4 changed after its traced compile"} =
               Rebar.coverage(ebin, c)

      File.write!(Path.join(ebin, "r4.beam"), "beam r4")

      # A compile line without the hash proves nothing about the bytes.
      unhashed = %{c | compiles: [Map.delete(ok.("r3"), "beam_sha256") | tl(c.compiles)]}

      assert {:error, "rebar3 compile of r3 recorded no beam hash"} =
               Rebar.coverage(ebin, unhashed)

      # A module compiled twice is held to its last compile.
      twice = %{c | compiles: c.compiles ++ [%{ok.("r3") | "beam_sha256" => sha.("r4")}]}

      assert {:error, "rebar3 beam r3 changed after its traced compile"} =
               Rebar.coverage(ebin, twice)

      assert {:error, "rebar3 trace sentinel missing"} =
               Rebar.coverage(ebin, %{c | sentinel?: false})

      assert {:error, "rebar3 trace incomplete"} = Rebar.coverage(ebin, %{c | problems: ["x"]})

      # At most one missing return per child is a gap; two or more taint.
      assert {:gap, "r5"} = Rebar.coverage(ebin, %{c | compiles: Enum.map(["r3", "r4"], ok)})

      assert {:error, "rebar3 compile of r4, r5 was not traced"} =
               Rebar.coverage(ebin, %{c | compiles: [ok.("r3")]})

      assert {:error, "rebar3 compile of r3, r4, r5 was not traced"} =
               Rebar.coverage(ebin, %{c | compiles: []})

      # A compile that returned an error is never a gap: could not be judged.
      failed = %{c | compiles: [%{"result" => "error", "module" => nil} | tl(c.compiles)]}
      assert {:unjudged, "rebar3 compile returned an error"} = Rebar.coverage(ebin, failed)

      all_ok_one_error = %{c | compiles: c.compiles ++ [%{"result" => "error", "module" => nil}]}

      assert {:unjudged, "rebar3 compile returned an error"} =
               Rebar.coverage(ebin, all_ok_one_error)

      assert {:error, "rebar3 compile was not traced"} = Rebar.coverage(ebin, nil)
      assert {:unjudged, "rebar3 ebin missing"} = Rebar.coverage(Path.join(dir, "none"), c)
      assert {:unjudged, "rebar3 ebin missing"} = Rebar.coverage(nil, c)
    end
  end

  # A Hex tarball whose `metadata.config` lists `build_tools`.
  defp tools_tarball(build_tools) do
    meta = ~s({<<"build_tools">>,[#{Enum.map_join(build_tools, ",", &~s(<<"#{&1}">>))}]}.\n)
    path = Path.join(System.tmp_dir!(), "ncc-tools-#{System.unique_integer([:positive])}.tar")

    :ok =
      :erl_tar.create(String.to_charlist(path), [{~c"VERSION", "3"}, {~c"metadata.config", meta}])

    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end

  describe "item 1: the manager of a declassified dependency" do
    test "must be the one the trace's closure line records", %{proj: proj} do
      r = report(proj)

      assert %{status: :pass, manager: "mix"} = judge(proj, r, declassified: %{"dep" => "mix"})

      assert %{status: :skip, reason: "manager mismatch: dep (trace mix, tarball rebar3)"} =
               judge(proj, r, declassified: %{"dep" => "rebar3"})

      # Outside the package's closure it does not count.
      assert %{status: :pass} = judge(proj, r, declassified: %{"other" => "rebar3"})
    end

    test "a closure line without a manager refuses", %{proj: proj} do
      r = report(proj)

      deps =
        for d <- r.closure["deps"],
            do: if(d["app"] == "dep", do: Map.put(d, "manager", nil), else: d)

      r = %{r | closure: %{r.closure | "deps" => deps}}

      assert %{status: :skip, reason: "manager mismatch: dep (trace none, tarball mix)"} =
               judge(proj, r, declassified: %{"dep" => "mix"})
    end

    # Spec item 1: a `[:make]` lock entry under a rebar3 parent. Mix takes
    # the parent's manager (the trace says rebar3), the lock and files say
    # otherwise: `NativeBuild.split/1`'s answer, held to the trace, refuses.
    # With only a Makefile, the files say make: never declassified, it stays
    # native and the manager check has nothing to hold.
    test "a [:make] lock entry under a rebar3 parent, through split/2", %{proj: proj, dir: dir} do
      split = fn files ->
        root = Path.join(dir, "split#{System.unique_integer([:positive])}")
        dest = Path.join([root, "deps", "dep"])
        File.mkdir_p!(dest)
        Enum.each(files, fn {name, body} -> File.write!(Path.join(dest, name), body) end)

        File.write!(
          Path.join(root, "mix.lock"),
          ~s(%{"dep": {:hex, :dep, "1.0.0", "i", [:make], [], "hexpm", "o"}}\n)
        )

        NccWorker.NativeBuild.split(root, fn "dep" -> tools_tarball(["make"]) end)
      end

      r = report(proj)

      deps =
        for d <- r.closure["deps"],
            do: if(d["app"] == "dep", do: dep(proj, "dep", [], "rebar3"), else: d)

      r = %{r | closure: %{r.closure | "deps" => deps}}

      assert {[], %{"dep" => "mix"} = declassified} =
               split.(%{"Makefile" => "all:\n", "mix.exs" => ""})

      assert %{status: :skip, reason: "manager mismatch: dep (trace rebar3, tarball mix)"} =
               judge(proj, r, declassified: declassified)

      assert {["dep"], %{} = none} = split.(%{"Makefile" => "all:\n"})
      assert none == %{}
      refute match?(%{reason: "manager mismatch: " <> _}, judge(proj, r, declassified: none))
    end
  end

  describe "run/3" do
    test "without a pre-compile lock snapshot nothing runs", %{proj: proj, dir: dir} do
      trace_dir = Path.join(dir, "trace")

      assert %{status: :skip, reason: @cnj, observations: obs} =
               Portability.run(proj, "pkg", env: [], trace_dir: trace_dir)

      assert ["no mix.lock snapshot taken before the compile"] = obs["problems"]
      assert is_integer(obs["trace_stats"]["wall_ms"])
      assert obs["trace_stats"]["judge_compile"] == "not_run"
      assert obs["trace_stats"]["transient"] == true
      refute File.exists?(trace_dir)
    end

    test "passes run_started_at to the tracer: an exhausted run budget is not judged",
         %{proj: proj, dir: dir} do
      started = System.monotonic_time(:second) - 3 * 60 * 60

      assert %{status: :skip, reason: @cnj, observations: %{"problems" => [problem]} = obs} =
               Portability.run(proj, "pkg",
                 env: [],
                 releases: %{},
                 trace_dir: Path.join(dir, "trace"),
                 run_started_at: started
               )

      assert problem =~ "run_budget_exhausted"
      # Not finished: the worker must not judge whatever `_build` holds.
      assert obs["trace_stats"]["judge_compile"] == "not_finished"
      # Nothing about the package: a later run may well judge it.
      assert obs["trace_stats"]["transient"] == true
    end

    test "the native list is today's with the flag off and item 1's with it on",
         %{proj: proj, dir: dir} do
      File.write!(Path.join([proj, "deps", "dep", "Makefile"]), "all:\n")
      home = Path.join(dir, "hex")
      File.mkdir_p!(Path.join(home, "packages/hexpm"))
      tar = Path.join(home, "packages/hexpm/dep-1.0.0.tar")
      File.write!(tar, tools_tarball(["rebar3"]))
      sum = :sha256 |> :crypto.hash(File.read!(tar)) |> Base.encode16(case: :lower)
      releases = %{"dep" => %{name: "dep", version: "1.0.0", checksum: sum}}

      File.write!(
        Path.join(proj, "mix.lock"),
        ~s(%{"dep": {:hex, :dep, "1.0.0", "i", [:rebar3], [], "hexpm", "#{sum}"}}\n)
      )

      test_pid = self()

      capture = fn _caller, _ref, _command, [_args, _dir, env], _log ->
        {_, native} = List.keyfind(env, "NCC_TRACE_NATIVE", 0)
        send(test_pid, {:native, String.split(native, ",", trim: true)})
        {:ok, 0}
      end

      for {rule2, native} <- [{false, ["dep"]}, {true, []}, {"true", ["dep"]}] do
        Portability.run(proj, "pkg",
          env: [],
          releases: releases,
          hex_home: home,
          trace_dir: Path.join(dir, "trace#{System.unique_integer([:positive])}"),
          cmd: capture,
          reap: fn _ -> :ok end,
          makefile_rule2: rule2
        )

        assert_received {:native, ^native}, inspect(rule2)
      end

      # Without a verified tarball, the lock's rebar3 declassifies nothing.
      Portability.run(proj, "pkg",
        env: [],
        releases: releases,
        hex_home: Path.join(dir, "nohex"),
        trace_dir: Path.join(dir, "trace-nohex"),
        cmd: capture,
        reap: fn _ -> :ok end,
        makefile_rule2: true
      )

      assert_received {:native, ["dep"]}
    end

    test "unsplit/2 makes any verdict could-not-judge and keeps the problem" do
      pass = %{status: :pass, reason: nil, compile_env: [], observations: %{"problems" => []}}
      assert Portability.unsplit(pass, nil) == pass

      assert %{
               status: :skip,
               reason: @cnj,
               compile_env: nil,
               observations: %{"problems" => ["p"]}
             } =
               Portability.unsplit(pass, "p")
    end

    test "with makefile_rule2 a deps/ that cannot be listed is could-not-judge",
         %{proj: proj, dir: dir} do
      File.rm_rf!(Path.join(proj, "deps"))

      finishing = fn _caller, _ref, _command, _argv, _log -> {:ok, 0} end

      for rule2 <- [true, false] do
        assert %{status: :skip, reason: @cnj, observations: obs} =
                 Portability.run(proj, "pkg",
                   env: [],
                   releases: %{},
                   trace_dir: Path.join(dir, "trace#{rule2}"),
                   cmd: finishing,
                   reap: fn _ -> :ok end,
                   makefile_rule2: rule2
                 )

        assert obs["trace_stats"]["judge_compile"] == "finished"
        assert obs["trace_stats"]["makefile_rule2"] == rule2

        assert Enum.any?(obs["problems"], &(&1 =~ "deps/ could not be listed")) == rule2
      end
    end

    test "never raises", %{proj: proj} do
      # No env: (required).
      assert %{status: :skip, reason: @cnj, observations: obs} =
               Portability.run(proj, "pkg", releases: %{})

      assert obs["trace_stats"]["judge_compile"] == "not_finished"
      assert obs["trace_stats"]["transient"] == true
    end

    test "lock_snapshot reads the project's Hex releases", %{proj: proj} do
      assert :error = Portability.lock_snapshot(Path.join(proj, "nowhere"))

      File.write!(
        Path.join(proj, "mix.lock"),
        ~s(%{"pkg": {:hex, :pkg_hex, "1.0.0", "inner", [:mix], [], "hexpm", "outer"}}\n)
      )

      assert {:ok, %{"pkg" => %{name: "pkg_hex", version: "1.0.0", checksum: "outer"}}} =
               Portability.lock_snapshot(proj)
    end
  end

  describe "a real traced compile" do
    @describetag timeout: 300_000
    # `elixir -S mix` evaluates bin/mix as elixir_compiler_0 (no object
    # file); the tracer counts that one frame, by the script's real path, as
    # toolchain, so a clean closure has no user-extent event at all.

    alias NccWorker.TracerFixtures

    test "run/3 passes a clean closure and refuses a compile-time OS read", %{tmp_dir: dir} do
      root = Path.join(dir, "real")

      proj =
        TracerFixtures.project(root, ["fx_judge_top"], %{
          "fx_judge_top" => %{
            deps: ["fx_judge_leaf"],
            files: %{
              "lib/fx_judge_top.ex" => TracerFixtures.attr_module("FxJudgeTop", "FxJudgeLeaf.f()")
            }
          },
          "fx_judge_leaf" =>
            TracerFixtures.lib(
              "fx_judge_leaf",
              "defmodule FxJudgeLeaf do\n  def f, do: :ok\nend\n"
            )
        })

      opts = [
        env: TracerFixtures.env(proj),
        releases: %{},
        log_file: Path.join(root, "trace.log"),
        timeout_ms: 240_000,
        run_started_at: System.monotonic_time(:second)
      ]

      assert %{status: :pass, observations: obs} = Portability.run(proj, "fx_judge_top", opts),
             File.read!(Path.join(root, "trace.log"))

      assert is_integer(obs["trace_stats"]["wall_ms"])
      assert obs["trace_stats"]["windows"] == 2
      assert obs["trace_stats"]["judge_compile"] == "finished"
      assert obs["trace_stats"]["transient"] == false

      leaf = Path.join([proj, "deps", "fx_judge_leaf", "lib", "fx_judge_leaf.ex"])
      File.write!(leaf, TracerFixtures.attr_module("FxJudgeLeaf", ":os.version()") <> "\n")

      File.write!(
        leaf,
        String.replace(File.read!(leaf), "def x, do: @x", "def x, do: @x\n  def f, do: :ok")
      )

      assert %{
               reason:
                 "closure dependency observed the host: fx_judge_leaf (compile-time host read: os:version/0" <>
                   _
             } =
               Portability.run(proj, "fx_judge_top", opts)

      traced = TracerFixtures.trace(proj, ["fx_judge_leaf"])

      assert %{reason: "compile-time host read: os:version/0" <> _} =
               TracerFixtures.judge(proj, "fx_judge_leaf", traced)
    end
  end

  describe "compile-time config reads (R5) and the Elixir-patch rule" do
    defp config_event(ts, app, key, kind \\ "user") do
      ts
      |> event("application:get_env/2", "lib/x.ex", "config")
      |> Map.merge(%{
        "arg" => %{
          "app" => app,
          "key" => key,
          "app_name" => app,
          "key_name" => key,
          "atoms" => true
        },
        "first_kind" => kind
      })
    end

    defp version_event(ts, mfa, arg \\ %{}) do
      ts
      |> event(mfa, "lib/x.ex", "elixir_version")
      |> Map.merge(%{"arg" => arg, "first_kind" => "user"})
    end

    test "a pass carries the closure's reads, valued from the snapshot", %{proj: proj} do
      events = [
        config_event(35, "fx", "k"),
        # dep reads its own application, which the config leaves unset.
        config_event(15, "dep", "mode"),
        # In `other`'s window: not pkg's closure.
        config_event(25, "other_app", "z")
      ]

      snap = %{@snap | entries: %{{"fx", "k"} => enc({:ok, 1})}}

      assert %{status: :pass, compile_env: items, observations: obs} =
               judge(proj, traced(proj, events, snap))

      assert items == [
               %{app: "dep", path: ["mode"], value: enc(:error)},
               %{app: "fx", path: ["k"], value: enc({:ok, 1})}
             ]

      assert obs["trace_stats"]["config_items"] == 2
      assert obs["trace_stats"]["config_dropped"] == 0
      assert obs["config_unreviewed"] == []
    end

    test "two owners reading the same key make one item", %{proj: proj} do
      events = [config_event(15, "fx", "k"), config_event(35, "fx", "k")]
      snap = %{@snap | entries: %{{"fx", "k"} => enc({:ok, 1})}}

      assert %{status: :pass, compile_env: [%{app: "fx", path: ["k"], value: value}]} =
               judge(proj, traced(proj, events, snap))

      assert value == enc({:ok, 1})
    end

    test "a pass with no reads carries an empty list", %{proj: proj} do
      assert %{status: :pass, compile_env: []} = judge(proj, traced(proj, [], nil))
    end

    test "an unset key outside the reader's tree publishes with a config_order item",
         %{proj: proj} do
      assert %{status: :pass, compile_env: [], compile_inputs: [item]} =
               judge(proj, traced(proj, [config_event(35, "fx", "k")], @snap))

      assert %{"kind" => "config_order", "app" => "fx", "path" => ["k"]} = item
      assert Map.keys(item) |> Enum.sort() == ~w(app default kind path reader seen)
    end

    test "a truncated snapshot publishes with config_unrecorded", %{proj: proj} do
      snap = %{@snap | truncated: true}

      assert %{status: :pass, compile_inputs: [%{"kind" => "config_unrecorded"}]} =
               judge(proj, traced(proj, [config_event(35, "fx", "k")], snap))
    end

    test "the judge revision is 29, 30 with item 1 on" do
      assert NccWorker.Portability.judge_revision() == 29
      assert NccWorker.Portability.judge_revision(makefile_rule2: true) == 30

      # The portal withdraws only on refusals of a judge at least this new.
      # Revision 5 only loosens what revision 3 refused, so a revision 3 or 4
      # refusal still withdraws: one the current judge would publish is a
      # false miss until its rebuild, never a false hit.
      assert NccWorker.Portability.judge_revision() >=
               Compatibility.Portability.withdrawal_judge_revision()

      assert Compatibility.Portability.withdrawal_judge_revision() == 3
    end

    test "get_all_env of its own app or one in its tree passes with one config_all input each",
         %{proj: proj} do
      all = fn ts, app ->
        ts
        |> event("application:get_all_env/1", "lib/x.ex", "config")
        |> Map.merge(%{
          "arg" => %{"app" => app, "app_name" => app, "all" => true},
          "first_kind" => "user"
        })
      end

      snap = %{@snap | entries: %{{"dep", "mode"} => enc({:ok, :fast})}}

      assert %{status: :pass, compile_inputs: inputs} =
               judge(
                 proj,
                 traced(proj, [all.(35, "pkg"), all.(35, "dep"), all.(15, "dep")], snap)
               )

      assert inputs == [
               %{
                 "kind" => "config_all",
                 "app" => "dep",
                 "entries" => [%{"key" => "mode", "value" => enc({:ok, :fast})}]
               },
               %{"kind" => "config_all", "app" => "pkg", "entries" => []}
             ]
    end

    test "get_all_env in the package's window refuses it; in a dependency's it taints",
         %{proj: proj} do
      all = fn ts ->
        ts
        |> event("application:get_all_env/1", "lib/x.ex", "config")
        |> Map.merge(%{
          "arg" => %{"app" => "fx", "app_name" => "fx", "all" => true},
          "first_kind" => "user"
        })
      end

      assert %{status: :skip, reason: "compile-time config read: " <> _, compile_env: nil} =
               judge(proj, traced(proj, [all.(35)], @snap))

      assert %{
               reason:
                 "closure dependency observed the host: dep (compile-time config read: " <> _
             } = judge(proj, traced(proj, [all.(15)], @snap))
    end

    test "reads with no snapshot cannot be judged", %{proj: proj} do
      assert %{status: :skip, reason: @cnj, compile_env: nil, observations: obs} =
               judge(proj, traced(proj, [config_event(35, "fx", "k")], nil))

      assert "no config snapshot" in obs["problems"]
    end

    test "an unreviewed toolchain read is flagged and cannot be judged", %{proj: proj} do
      r = traced(proj, [config_event(35, "mix", "new_key", "toolchain")], @snap)

      assert %{status: :skip, reason: @cnj, compile_env: nil, observations: obs} =
               judge(proj, r)

      assert [%{"owner" => "pkg", "first" => "Elixir.X"}] = obs["config_unreviewed"]
      assert "unreviewed toolchain config read: mix new_key from Elixir.X" in obs["problems"]
    end

    test "a reviewed toolchain read is recorded", %{proj: proj} do
      r =
        traced(proj, [config_event(35, "logger", "compile_time_purge_level", "toolchain")], @snap)

      assert %{status: :pass, compile_env: [%{app: "logger", path: ["compile_time_purge_level"]}]} =
               judge(proj, r)
    end

    test "an Elixir patch dependence refuses the package", %{proj: proj} do
      events = [
        version_event(35, "System.version/0"),
        version_event(36, "Version.match?/2", %{
          "left" => ~s("1.19.5"),
          "right" => ~s(">= 1.19.6")
        })
      ]

      assert %{
               status: :skip,
               reason: "compile-time Elixir patch dependence: Version.match?/2" <> _,
               compile_env: nil
             } = judge(proj, traced(proj, events, @snap))
    end

    test "an Elixir patch dependence in a dependency's window taints it", %{proj: proj} do
      events = [version_event(15, "System.build_info/0")]

      assert %{
               reason:
                 "closure dependency observed the host: dep (compile-time Elixir patch dependence: " <>
                   _
             } = judge(proj, traced(proj, events, @snap))
    end

    test "a minor-boundary Elixir version check passes", %{proj: proj} do
      events = [
        version_event(35, "System.version/0"),
        version_event(36, "Version.match?/2", %{
          "left" => ~s("1.19.5"),
          "right" => ~s(">= 1.19.0")
        })
      ]

      assert %{status: :pass, compile_env: []} = judge(proj, traced(proj, events, @snap))
    end

    test "Elixir version reads with no Elixir version cannot be judged", %{proj: proj} do
      r = report(proj, %{events: [version_event(35, "System.version/0")], config_env: @snap})

      assert %{status: :skip, reason: @cnj, observations: obs} = judge(proj, r)
      assert "no Elixir version in the trace" in obs["problems"]

      r = report(proj, %{events: [version_event(35, "System.build_info/0")], config_env: @snap})

      assert %{
               status: :skip,
               reason: "compile-time Elixir patch dependence: System.build_info/0" <> _
             } =
               judge(proj, r)
    end
  end

  describe "compile-time inputs" do
    defp env_event(ts, name, returned, file \\ "lib/x.ex") do
      ts
      |> event("os:getenv/1", file, "env")
      |> Map.merge(%{
        "arg" => %{"name" => name},
        "first_kind" => "user",
        "call_id" => ts,
        "returned" => returned
      })
    end

    test "an env read in the package's window publishes with a host input", %{proj: proj} do
      assert %{status: :pass, compile_inputs: [item]} =
               judge(proj, traced(proj, [env_event(35, "GITHUB_ACTIONS", enc(:error))], @snap))

      assert item == %{
               "kind" => "env",
               "name" => "GITHUB_ACTIONS",
               "value" => enc(:error),
               "set_by" => "host"
             }
    end

    test "an env read in a dependency's window no longer taints it", %{proj: proj} do
      assert %{status: :pass, compile_inputs: [%{"name" => "X"}]} =
               judge(proj, traced(proj, [env_event(15, "X", enc({:ok, "1"}))], @snap))
    end

    test "a pass with no reads carries empty inputs; a skip carries none", %{proj: proj} do
      assert %{status: :pass, compile_inputs: []} = judge(proj, traced(proj, [], @snap))
      cmd = event(35, "os:cmd/1", "lib/x.ex", "programs")
      assert %{status: :skip, compile_inputs: nil} = judge(proj, traced(proj, [cmd], @snap))
    end

    test "a private-looking name's value is in neither the inputs nor the observations",
         %{proj: proj} do
      secret = enc({:ok, "s3cret"})
      read = env_event(35, "FX_API_TOKEN", secret)

      write =
        35
        |> event("os:putenv/2", "lib/x.ex", "env_write")
        |> Map.put("arg", %{"name" => "NCC_SECRET_X", "value" => secret})

      assert %{status: :pass} = v = judge(proj, traced(proj, [write, read], @snap))
      refute inspect(v, limit: :infinity, printable_limit: :infinity) =~ secret
      assert [%{"value" => "unrecordable"}] = v.compile_inputs
      assert [read_obs] = v.observations["env_reads"]
      assert [write_obs] = v.observations["env_writes"]
      refute Map.has_key?(read_obs, "returned")
      refute Map.has_key?(write_obs, "value")
    end

    test "init arguments are still a host read", %{proj: proj} do
      arg = event(35, "init:get_argument/1", "lib/x.ex", "env")

      assert %{status: :skip, reason: "compile-time host read: init:get_argument/1" <> _} =
               judge(proj, traced(proj, [arg], @snap))
    end
  end

  test "a foreign priv write refuses in a firmware target's trace, flag or not", %{proj: proj} do
    path =
      Path.join(proj, "_build/host/lib/dep/priv/assets/Pkg_W/uxwh53kfq2wszgf23hqwgkuiza.tar.gz")

    e = %{
      event(35, "file:open/2", Path.join(proj, "deps/pkg/lib/pkg.ex"), "file_write")
      | "arg" => %{"path" => path}
    }

    r = report(proj, %{events: [e]})

    for flag <- [[foreign_priv: true], []] do
      assert %{status: :skip, reason: "compile-time write outside ebin: file:open/2 " <> _} =
               judge(proj, r, [nif_waiver: true, target: "rpi4"] ++ flag),
             inspect(flag)
    end
  end
end
