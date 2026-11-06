defmodule NccWorker.Portability.JudgeTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability
  alias NccWorker.Portability.{Context, Rebar}
  alias NccWorker.Tracer.Report

  @moduletag :tmp_dir

  @cnj "portability could not be judged"

  # The mapped libraries the VM started with (the tracer's snapshot).
  @libs %{"nif_check" => "ok", "mapped_libs" => ["/usr/lib/libc.so.6"]}

  # deps/<app> and _build/host/lib/<app>/ebin for `dep` and `pkg` (pkg
  # depends on dep), plus `other`, a closure dependency `pkg` does not reach.
  setup %{tmp_dir: dir} do
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
          %{app: "dep", ts: 11, integrity_ok: true},
          %{app: "other", ts: 22, integrity_ok: true},
          %{app: "pkg", ts: 31, integrity_ok: true}
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
        libs: []
      },
      extra
    )
  end

  defp judge(proj, report, opts \\ []), do: Portability.judge(proj, "pkg", report, [], opts)

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
               Portability.judge(proj, "pkg", r, ["dep"], nif_waiver: false)

      # Not native: the same library refuses.
      assert %{status: :skip, reason: "compile-time native library load: " <> _} =
               judge(proj, r, nif_waiver: false)
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
      assert %{status: :pass, reason: nil, observations: obs} = judge(proj, report(proj))

      assert %{"calls" => 10, "windows" => 3, "sentinels" => 3, "rebar3_untraced_last" => %{}} =
               obs["trace_stats"]

      assert obs["taint"] == %{}
      assert obs["problems"] == []
      assert obs["refusals"] == []
    end

    test "a refusal in the package's window is the reason", %{proj: proj} do
      r = report(proj, %{events: [event(35, "os:type/0", "lib/pkg.ex")]})

      assert %{status: :skip, reason: "compile-time host read: os:type/0" <> _, observations: obs} =
               judge(proj, r)

      assert [%{"owner" => "pkg", "reason" => "compile-time host read: os:type/0" <> _}] =
               obs["refusals"]
    end

    test "a refusal in a dependency's window taints it and refuses the package", %{proj: proj} do
      r = report(proj, %{events: [event(15, "os:type/0", "lib/dep.ex")]})

      assert %{
               status: :skip,
               reason:
                 "closure dependency observed the host: dep (compile-time host read: os:type/0" <>
                   _,
               observations: obs
             } = judge(proj, r)

      assert %{"dep" => "compile-time host read: os:type/0" <> _} = obs["taint"]
    end

    test "an event outside every window counts against everything", %{proj: proj} do
      r = report(proj, %{events: [event(25 + 100, "os:getenv/1", "lib/x.ex", "env")]})

      assert %{status: :skip, reason: "compile-time host read: os:getenv/1" <> _} =
               judge(proj, r)
    end

    test "a refusal in the package's window comes before taint", %{proj: proj} do
      r =
        report(proj, %{
          events: [event(15, "os:type/0", "lib/dep.ex"), event(35, "os:version/0", "lib/pkg.ex")]
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
            event(25, "os:type/0", "lib/other.ex"),
            event(15, "os:version/0", "lib/dep.ex")
          ]
      }

      assert %{reason: "closure dependency observed the host: dep (" <> _, observations: obs} =
               judge(proj, r)

      assert Map.keys(obs["taint"]) == ["dep", "other"]
    end
  end

  describe "fail closed (carry items)" do
    test "an event Events could not judge makes the verdict could-not-judge", %{proj: proj} do
      unjudged = %{event(35, "os:type/0", "lib/pkg.ex") | "extent" => "unjudged"}
      unknown = event(35, "x:y/0", "lib/pkg.ex", "no_such_channel")
      malformed = %{"ts" => 35, "mfa" => "os:type/0"}
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
      e = %{event(1, "os:type/0", "src/dep.erl") | "extent" => "unjudged"}
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
          events: [event(55, "os:type/0", "x.erl")],
          quiet: [%{app: "dep", open: 50, close: 60, delivered: true}]
        })

      assert %{status: :pass} = judge(proj, r)
    end

    test "a stray child trace with no closure owner is ignored (Review Focus 2)", %{proj: proj} do
      stray =
        child([
          event(1, "os:type/0", "x.erl"),
          %{event(2, "os:getenv/1", "x.erl", "env") | "extent" => "unjudged"},
          event(3, "erlang:process_info/2", "x.erl", "integrity")
        ])

      r = report(proj, %{children: %{"unknown" => %{stray | start: %{"app" => "unknown"}}}})
      assert %{status: :pass, observations: obs} = judge(proj, r)
      assert obs["refusals"] == []
    end

    test "child VM events count against their app, not the Mix VM's window", %{proj: proj} do
      # ts 35 is inside pkg's window in the Mix VM clock; it belongs to dep.
      r = report(proj, %{children: %{"dep" => child([event(35, "os:type/0", "src/dep.erl")])}})

      assert %{reason: "closure dependency observed the host: dep (compile-time host read" <> _} =
               judge(proj, r)
    end

    test "only the package's closure counts (ruling M7)", %{proj: proj} do
      config = %{
        event(25, "application:get_env/2", "lib/other.ex", "config")
        | "arg" => %{"app" => "fx", "key" => "k"}
      }

      r =
        report(proj, %{
          events: [event(25, "os:type/0", "lib/other.ex"), config],
          children: %{"other" => child([event(1, "os:version/0", "src/other.erl")])}
        })

      assert %{status: :pass, observations: obs} = judge(proj, r)
      assert obs["refusals"] == []
      assert obs["config_reads"] == []
      assert obs["taint"] == %{}
    end

    test "an integrity refusal outside the package's closure still refuses (fix round 1)",
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
          events: [event(15, "os:type/0", "lib/dep.ex")]
      }

      assert %{
               status: :skip,
               reason: "closure dependency observed the host: dep (compile-time host read" <> _,
               observations: %{"taint" => %{"dep" => _}}
             } = judge(proj, r)
    end

    test "a judge that raises is could-not-judge, never a crash", %{proj: proj} do
      assert %{status: :skip, reason: @cnj} = judge(proj, report(proj, %{events: :garbage}))
      assert %{status: :skip, reason: @cnj} = judge(proj, report(proj, %{windows: [:garbage]}))
      assert %{status: :skip, reason: @cnj} = Portability.judge(proj, "pkg", %{}, [])
    end
  end

  describe "observations" do
    test "config reads are observed with their owner, without refusing", %{proj: proj} do
      config = %{
        "ts" => 35,
        "channel" => "config",
        "mfa" => "application:get_env/2",
        "arg" => %{"app" => "fx", "key" => "k"},
        "extent" => "frame",
        "first" => %{"module" => "Elixir.X"},
        "user" => %{"module" => "Elixir.X"}
      }

      assert %{
               status: :pass,
               observations: %{
                 "config_reads" => [%{"owner" => "pkg", "arg" => %{"key" => "k"}}]
               }
             } = judge(proj, report(proj, %{events: [config]}))
    end

    test "config reads are capped at 200", %{proj: proj} do
      events =
        for n <- 1..250 do
          %{
            event(35, "application:get_env/2", "lib/pkg.ex", "config")
            | "arg" => %{"app" => "fx", "key" => "k#{n}"}
          }
        end

      assert %{observations: %{"config_reads" => reads}} =
               judge(proj, report(proj, %{events: events}))

      assert length(reads) == 200
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
      %{
        event(15, "os:getenv/1", Path.join([proj, "deps", "dep", "mix.exs"]), "env")
        | "arg" => %{"name" => "XV"}
      }
      |> put_in(["user", "line"], line)
    end

    test "an allowed mix.exs read is observed; a compile-relevant one taints", %{proj: proj} do
      assert %{status: :pass, observations: %{"mix_exs_allowed" => [%{"owner" => "dep"}]}} =
               judge(proj, report(proj, %{events: [mix_exs_read(proj, 4)]}))

      r = report(proj, %{events: [mix_exs_read(proj, 4), mix_exs_read(proj, 5)]})

      assert %{
               reason:
                 "closure dependency observed the host: dep (compile-time host read in mix.exs: os:getenv/1 sets elixirc_options" <>
                   _
             } = judge(proj, r)
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

  describe "Context inputs (carry: lock snapshot, Hex cache)" do
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
    defp rebar_report(proj, rebar_app, children) do
      r = report(proj, %{children: children})

      deps =
        for d <- r.closure["deps"],
            do: if(d["app"] == rebar_app, do: %{d | "manager" => "rebar3"}, else: d)

      %{r | closure: %{r.closure | "deps" => deps}}
    end

    # A real (R2-clean) beam of an empty module `Elixir.<name>`.
    defp beam!(proj, app, name), do: write_beam(proj, app, "defmodule #{name} do\nend\n")

    test "the package: hooks refuse, missing coverage could not be judged", %{proj: proj} do
      File.write!(
        Path.join([proj, "deps/pkg/rebar.config"]),
        ~s({pre_hooks, [{compile, "make"}]}.\n)
      )

      assert %{reason: "rebar3 build runs pre_hooks"} =
               judge(proj, rebar_report(proj, "pkg", %{}))

      File.write!(Path.join([proj, "deps/pkg/rebar.config"]), "{erl_opts, []}.\n")
      assert %{status: :pass} = judge(proj, rebar_report(proj, "pkg", %{"pkg" => child([])}))
      assert %{status: :skip, reason: @cnj} = judge(proj, rebar_report(proj, "pkg", %{}))

      # Beams the trace never saw compiled (two: past the one-gap allowance).
      for m <- ["JudgeRebarA", "JudgeRebarB"], do: beam!(proj, "pkg", m)
      assert %{status: :skip, reason: @cnj} = judge(proj, rebar_report(proj, "pkg", %{}))
    end

    test "a dependency: plugins and missing coverage taint", %{proj: proj} do
      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{plugins, [pc]}.\n")

      assert %{reason: "closure dependency observed the host: dep (rebar3 build runs plugins)"} =
               judge(proj, rebar_report(proj, "dep", %{}))

      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{erl_opts, []}.\n")
      beam!(proj, "dep", "JudgeRebarD1")

      assert %{
               reason: "closure dependency observed the host: dep (rebar3 compile was not traced)"
             } =
               judge(proj, rebar_report(proj, "dep", %{}))

      sentinel_lost =
        child([], %{
          sentinel?: false,
          compiles: [%{"result" => "ok", "module" => "Elixir.JudgeRebarD1"}]
        })

      assert %{
               reason: "closure dependency observed the host: dep (rebar3 trace sentinel missing)"
             } =
               judge(proj, rebar_report(proj, "dep", %{"dep" => sentinel_lost}))
    end

    test "a dependency compile that returned an error could not be judged", %{proj: proj} do
      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{erl_opts, []}.\n")
      beam!(proj, "dep", "JudgeRebarE1")

      traced =
        child([], %{
          compiles: [
            %{"result" => "ok", "module" => "Elixir.JudgeRebarE1"},
            %{"result" => "error", "module" => nil}
          ]
        })

      assert %{status: :skip, reason: @cnj, observations: obs} =
               judge(proj, rebar_report(proj, "dep", %{"dep" => traced}))

      assert obs["taint"] == %{}
      assert Enum.any?(obs["problems"], &(&1 =~ "rebar3 compile returned an error"))
    end

    test "a rebar3 dependency with an empty ebin and no child trace could not be judged",
         %{proj: proj} do
      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{erl_opts, []}.\n")
      assert %{status: :skip, reason: @cnj} = judge(proj, rebar_report(proj, "dep", %{}))
    end

    test "one lost last compile return is recorded in trace_stats, not taint (ruling M2)",
         %{proj: proj} do
      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{erl_opts, []}.\n")
      for m <- ["JudgeRebarG1", "JudgeRebarG2"], do: beam!(proj, "dep", m)
      traced = child([], %{compiles: [%{"result" => "ok", "module" => "Elixir.JudgeRebarG1"}]})

      assert %{status: :pass, observations: obs} =
               judge(proj, rebar_report(proj, "dep", %{"dep" => traced}))

      assert obs["trace_stats"]["rebar3_untraced_last"] == %{"dep" => "Elixir.JudgeRebarG2"}
      assert obs["taint"] == %{}
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
            {"pplugins", "{project_plugins, [rebar3_hex]}.\n",
             "rebar3 build runs project_plugins"},
            {"pd", ~s({erl_opts, [{platform_define, "win32", 'WIN'}]}.\n),
             "rebar3 build uses platform_define"},
            {"profile", ~s({profiles, [{prod, [{pre_hooks, [{compile, "make"}]}]}]}.\n),
             "rebar3 build runs pre_hooks"},
            {"profile_pd",
             ~s({profiles, [{prod, [{erl_opts, [{platform_define, "x", 'X'}]}]}]}.\n),
             "rebar3 build uses platform_define"},
            {"garbled", "{erl_opts, [\n", "rebar3 build config unreadable"},
            {"macro", "{erl_opts, [?X]}.\n", "rebar3 build config unreadable"}
          ] do
        assert {:refuse, ^reason} = Rebar.check(write(dir, name, %{"rebar.config" => config})),
               name
      end

      assert {:refuse, "rebar3 build evaluates rebar.config.script"} =
               Rebar.check(
                 write(dir, "script", %{
                   "rebar.config" => "{erl_opts, []}.\n",
                   "rebar.config.script" => "CONFIG.\n"
                 })
               )

      # No atom is created from the config.
      atom = "ncc_rebar_never_an_atom_#{System.unique_integer([:positive])}"
      assert :ok = Rebar.check(write(dir, "atom", %{"rebar.config" => "{#{atom}, []}.\n"}))
      assert_raise ArgumentError, fn -> String.to_existing_atom(atom) end
    end

    test "coverage needs a sentinel and a traced compile:file per beam", %{tmp_dir: dir} do
      ebin = Path.join(dir, "ebin")
      File.mkdir_p!(ebin)

      # An empty ebin with no child trace proves nothing (fix round 1, item 5).
      assert {:unjudged, "rebar3 built nothing and was not traced"} = Rebar.coverage(ebin, nil)
      assert :ok = Rebar.coverage(ebin, child([]))

      for m <- ["r3", "r4", "r5"], do: File.write!(Path.join(ebin, m <> ".beam"), "")

      ok = fn m -> %{"result" => "ok", "module" => m} end
      c = child([], %{compiles: Enum.map(["r3", "r4", "r5"], ok)})

      assert :ok = Rebar.coverage(ebin, c)

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

  describe "run/3" do
    test "without a pre-compile lock snapshot nothing runs", %{proj: proj, dir: dir} do
      trace_dir = Path.join(dir, "trace")

      assert %{status: :skip, reason: @cnj, observations: obs} =
               Portability.run(proj, "pkg", env: [], trace_dir: trace_dir)

      assert ["no mix.lock snapshot taken before the compile"] = obs["problems"]
      assert is_integer(obs["trace_stats"]["wall_ms"])
      refute File.exists?(trace_dir)
    end

    test "passes run_started_at to the tracer: an exhausted run budget is not judged",
         %{proj: proj, dir: dir} do
      started = System.monotonic_time(:second) - 3 * 60 * 60

      assert %{status: :skip, reason: @cnj, observations: %{"problems" => [problem]}} =
               Portability.run(proj, "pkg",
                 env: [],
                 releases: %{},
                 trace_dir: Path.join(dir, "trace"),
                 run_started_at: started
               )

      assert problem =~ "run_budget_exhausted"
    end

    test "never raises", %{proj: proj} do
      # No env: (required).
      assert %{status: :skip, reason: @cnj} = Portability.run(proj, "pkg", releases: %{})
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

      leaf = Path.join([proj, "deps", "fx_judge_leaf", "lib", "fx_judge_leaf.ex"])
      File.write!(leaf, TracerFixtures.attr_module("FxJudgeLeaf", ":os.type()") <> "\n")

      File.write!(
        leaf,
        String.replace(File.read!(leaf), "def x, do: @x", "def x, do: @x\n  def f, do: :ok")
      )

      assert %{
               reason:
                 "closure dependency observed the host: fx_judge_leaf (compile-time host read: os:type/0" <>
                   _
             } =
               Portability.run(proj, "fx_judge_top", opts)

      traced = TracerFixtures.trace(proj, ["fx_judge_leaf"])

      assert %{reason: "compile-time host read: os:type/0" <> _} =
               TracerFixtures.judge(proj, "fx_judge_leaf", traced)
    end
  end
end
