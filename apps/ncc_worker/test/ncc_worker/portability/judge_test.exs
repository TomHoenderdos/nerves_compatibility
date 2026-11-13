defmodule NccWorker.Portability.JudgeTest do
  # Starts real `elixir` VMs: one such module at a time (the :real_vm
  # group), alongside the unit suites, so their compiles do not contend.
  use ExUnit.Case, async: true, group: :real_vm

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
      r = report(proj, %{events: [event(25 + 100, "os:cmd/1", "lib/x.ex", "programs")]})

      assert %{status: :skip, reason: "compile-time host read: os:cmd/1" <> _} =
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

  # The setup's project with a report that passes as it is.
  defp clean_judged_project(proj), do: {proj, report(proj)}

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

    test "a stray child trace with no closure owner is ignored", %{proj: proj} do
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

    test "only the package's closure counts", %{proj: proj} do
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

    test "a dependency whose mix.rebar.config is missing could not be judged", %{proj: proj} do
      File.write!(Path.join([proj, "deps/dep/rebar.config"]), "{erl_opts, []}.\n")
      r = rebar_report(proj, "dep", %{"dep" => child([])})
      File.rm!(Path.join([proj, "_build/host/lib/dep/mix.rebar.config"]))

      assert %{status: :skip, reason: @cnj, observations: obs} =
               judge(proj, r, rebar_opts(proj, ["dep"]))

      assert obs["taint"] == %{}
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
            %{"result" => "ok", "module" => "Elixir.JudgeRebarE1"},
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
      traced = child([], %{compiles: [%{"result" => "ok", "module" => "Elixir.JudgeRebarG1"}]})

      assert %{status: :pass, observations: obs} =
               rjudge(proj, "dep", %{"dep" => traced})

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
            {"pd", ~s({erl_opts, [{platform_define, "win32", 'WIN'}]}.\n),
             "rebar3 build uses platform_define"},
            {"profile", ~s({profiles, [{prod, [{pre_hooks, [{compile, "make"}]}]}]}.\n),
             "rebar3 build runs pre_hooks"},
            {"profile_pd",
             ~s({profiles, [{prod, [{erl_opts, [{platform_define, "x", 'X'}]}]}]}.\n),
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
            {"test_override",
             ~s({profiles, [{test, [{overrides, [{override, [{pre_hooks, [{compile, "x"}]}]}]}]}]}.\n)}
          ] do
        assert :ok = Rebar.check(write(dir, name, %{"rebar.config" => config})), name
      end

      # No atom is created from the config.
      atom = "ncc_rebar_never_an_atom_#{System.unique_integer([:positive])}"
      assert :ok = Rebar.check(write(dir, "atom", %{"rebar.config" => "{#{atom}, []}.\n"}))
      assert_raise ArgumentError, fn -> String.to_existing_atom(atom) end
    end

    # The real files of the 2026-11-06 benchmark lock's releases, vendored
    # unchanged from their Hex tarballs.
    test "telemetry 1.4.2's and mimerl 1.5.0's real rebar.config do not taint", %{tmp_dir: dir} do
      for name <- ["telemetry-1.4.2", "mimerl-1.5.0"] do
        config = File.read!(Path.join([__DIR__, "../../fixtures/rebar", name <> ".rebar.config"]))
        assert :ok = Rebar.check(write(dir, name, %{"rebar.config" => config})), name
      end
    end

    test "hackney 4.9.1's real rebar.config reads (erl_scan escapes) and refuses",
         %{tmp_dir: dir} do
      config =
        File.read!(Path.join([__DIR__, "../../fixtures/rebar/hackney-4.9.1.rebar.config"]))

      # A top-level `{pre_hooks, [{clean, "rm -rf ..."}]}`: any non-empty
      # hook list refuses (fail closed), before its platform_define.
      assert {:refuse, "rebar3 build runs pre_hooks"} =
               Rebar.check(write(dir, "hackney", %{"rebar.config" => config}))

      without_hook =
        String.replace(
          config,
          ~s({pre_hooks, [{clean, "rm -rf *~ */*~ */*.xfm test/*.beam"}]}.),
          ""
        )

      assert {:refuse, "rebar3 build uses platform_define"} =
               Rebar.check(write(dir, "hackney_pd", %{"rebar.config" => without_hook}))

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

      # A parent's script still leaves the overrides it hands down unknown.
      assert {:unjudged, "a rebar3 parent evaluates rebar.config.script"} =
               Rebar.check_sources(
                 %{config: "{erl_opts, []}.\n", script?: false},
                 [%{config: "{erl_opts, []}.\n", script?: true}],
                 mix_config
               )
    end

    test "coverage needs a sentinel and a traced compile:file per beam", %{tmp_dir: dir} do
      ebin = Path.join(dir, "ebin")
      File.mkdir_p!(ebin)

      # An empty ebin with no child trace proves nothing.
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

    test "the judge revision is 3, 4 with item 1 on" do
      assert NccWorker.Portability.judge_revision() == 3
      assert NccWorker.Portability.judge_revision(makefile_rule2: true) == 4

      # The portal withdraws only on refusals of a judge at least this new.
      assert NccWorker.Portability.judge_revision() ==
               Compatibility.Portability.withdrawal_judge_revision()
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
end
