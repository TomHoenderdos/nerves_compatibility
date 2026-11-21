defmodule NccWorker.Portability.EventsTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability.{Context, Events}
  alias NccWorker.Tracer.Report

  @moduletag :tmp_dir

  @mix_exs """
  defmodule Pkg.MixProject do
    use Mix.Project
    def project, do: [app: :pkg, version: "1.0.0", deps: deps(), elixirc_options: opts()]
    defp deps, do: [{:x, System.get_env("XV") || "~> 1.0"}]
    defp opts, do: [debug_info: System.get_env("DBG") == "1"]
  end
  """

  setup %{tmp_dir: dir} do
    proj = Path.join(dir, "proj")
    pkg = Path.join([proj, "deps", "pkg"])
    File.mkdir_p!(Path.join(pkg, "lib"))
    File.mkdir_p!(Path.join(proj, "_build/host/lib/pkg/ebin"))
    File.write!(Path.join(pkg, "README.md"), "")
    File.write!(Path.join(pkg, "mix.exs"), @mix_exs)
    File.write!(Path.join(proj, "mix.exs"), "")

    report = report(dir, proj, pkg, [])
    %{dir: dir, proj: proj, pkg: pkg, ctx: build(dir, proj, report)}
  end

  defp report(dir, proj, pkg, events) do
    %Report{
      start: %{"otp_root" => Path.join(dir, "otp")},
      closure: %{
        "packages" => ["pkg"],
        "deps" => [
          %{
            "app" => "pkg",
            "dest" => pkg,
            "build" => Path.join(proj, "_build/host/lib/pkg"),
            "manager" => "mix",
            "children" => []
          }
        ]
      },
      windows: [%{app: "pkg", open: 0, close: 100, depth_ok: true}],
      events: events
    }
  end

  # The run's Hex cache: pkg's verified tarball lists lib, README.md and mix.exs.
  defp build(dir, proj, report, opts \\ []) do
    home = Path.join(dir, "hex-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "packages/hexpm"))
    files = Keyword.get(opts, :hex_files, ~w(lib README.md mix.exs))
    meta = ~s({<<"files">>,[#{Enum.map_join(files, ",", &~s(<<"#{&1}">>))}]}.\n)
    tar = Path.join(dir, "pkg-#{System.unique_integer([:positive])}.tar")

    :ok =
      :erl_tar.create(String.to_charlist(tar), [{~c"VERSION", "3"}, {~c"metadata.config", meta}])

    bytes = File.read!(tar)
    File.write!(Path.join(home, "packages/hexpm/pkg-1.0.0.tar"), bytes)
    sum = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

    Context.build(
      proj,
      "pkg",
      report,
      Keyword.get(opts, :native, []),
      Keyword.merge(
        [hex_home: home, releases: %{"pkg" => %{name: "pkg", version: "1.0.0", checksum: sum}}],
        Keyword.drop(opts, [:native, :hex_files])
      )
    )
  end

  @user %{
    "module" => "Elixir.Pkg",
    "function" => "f",
    "arity" => 0,
    "file" => "lib/pkg.ex",
    "line" => 3
  }

  defp ev(channel, mfa, arg, opts \\ []) do
    %{
      "ts" => 50,
      "channel" => channel,
      "mfa" => mfa,
      "arg" => arg,
      "extent" => Keyword.get(opts, :extent, "frame"),
      "first" => first(opts),
      "user" => Keyword.get(opts, :user, @user)
    }
  end

  defp first(opts) do
    case Keyword.get(opts, :first, "Elixir.Pkg") do
      {m, f, a} -> %{"module" => m, "function" => f, "arity" => a}
      m -> %{"module" => m}
    end
  end

  defp in_mix_exs(event, pkg, line) do
    %{
      event
      | "user" => %{
          "module" => "Elixir.Pkg.MixProject",
          "function" => "deps",
          "arity" => 0,
          "file" => Path.join(pkg, "mix.exs"),
          "line" => line
        }
    }
  end

  @os_reads [
    {"os:type/0", :os, :type, %{}},
    {"os:version/0", :os, :version, %{}},
    {"erlang:system_info/1", :erlang, :system_info, %{"key" => "os_type"}}
  ]

  # The tracer writes no line for a read `:ncc_tracer_channels.path_os_read/3`
  # names whose first frame is one of its `path_os_frames/0` (it counts it):
  # the judge must ignore every such line wherever it falls, a mix.exs
  # included, or dropping it would change a verdict.
  test "every OS-family read the tracer only counts is ignored, for every owner", %{
    ctx: ctx,
    pkg: pkg
  } do
    for {mfa, m, f, arg} <- @os_reads,
        {fm, ff, fa} = frame <- :ncc_tracer_channels.path_os_frames(),
        extent <- ~w(frame dispatcher truncated lineage),
        owner <- ["pkg", "dep", :outside, :quiet, :wrapper] do
      assert :ncc_tracer_channels.path_os_read(m, f, atom_keys(arg))
      assert :ncc_tracer_channels.path_os_frame(fm, ff, fa)
      event = ev("os_identity", mfa, arg, first: frame, extent: extent)
      assert :ignore = Events.decide(event, ctx, owner), inspect({mfa, frame, extent, owner})
      assert :ignore = Events.decide(in_mix_exs(event, pkg, 3), ctx, owner)
    end

    refute :ncc_tracer_channels.path_os_read(:erlang, :system_info, %{key: "version"})
    refute :ncc_tracer_channels.path_os_read(:os, :getenv, %{})
  end

  # A package fun that tail-calls the read leaves the frame that called the
  # fun first: the module alone (Code, filelib, filename) says nothing.
  test "an OS-family read under any other frame of a path module is not path handling",
       %{ctx: ctx} do
    others = [
      {"Elixir.Code", "with_diagnostics", 2},
      {"Elixir.Code", "eval_string", 3},
      {"filelib", "fold_files", 5},
      {"filelib", "exists", 2},
      {"filelib", "do_fold_files2", 7},
      {"filelib", "wildcard", 2},
      {"file", "read_file", 1},
      {"code", "lib_dir", 1},
      {"filename", "-split/1-fun-0-", 1},
      {"filename", "split", 2},
      {"filename", "basedir_os_type", 0},
      {"filename", "validate", 1},
      {"Elixir.Path", "join", 2},
      {"Elixir.Path", "major_os_type", 1},
      "Elixir.Path",
      "filename"
    ]

    # os:version/0 refuses; the OS type is a compile input (revision 17).
    for {mfa, _m, _f, arg} <- @os_reads, frame <- others do
      expected =
        if mfa == "os:version/0",
          do: {:refuse, "compile-time host read: "},
          else: {:observe, "os_type_reads"}

      assert Events.decide(ev("os_identity", mfa, arg, first: frame), ctx, "pkg")
             |> then(fn
               {:refuse, "compile-time host read: " <> _} -> {:refuse, "compile-time host read: "}
               {:observe, "os_type_reads", %{"scope" => "full"}} -> {:observe, "os_type_reads"}
               other -> other
             end) == expected,
             inspect({mfa, frame})
    end
  end

  defp atom_keys(arg), do: Map.new(arg, fn {k, v} -> {String.to_atom(k), v} end)

  test "OS identity: path handling and the OTP release pass, a direct read is decided",
       %{ctx: ctx} do
    assert :ignore =
             Events.decide(
               ev("os_identity", "os:type/0", %{}, first: {"Elixir.Path", "major_os_type", 0}),
               ctx,
               "pkg"
             )

    assert :ignore =
             Events.decide(
               ev("os_identity", "os:type/0", %{}, first: {"filename", "split", 1}),
               ctx,
               "pkg"
             )

    assert :ignore =
             Events.decide(
               ev("os_identity", "erlang:system_info/1", %{"key" => "otp_release"}),
               ctx,
               "pkg"
             )

    assert {:refuse, "compile-time host read: os:version/0 in Pkg.f/0 (lib/pkg.ex:3)"} =
             Events.decide(ev("os_identity", "os:version/0", %{}), ctx, "pkg")

    assert {:observe, "os_type_reads",
            %{"mfa" => "os:type/0", "file" => "lib/pkg.ex", "line" => 3, "scope" => "full"}} =
             Events.decide(ev("os_identity", "os:type/0", %{}), ctx, "pkg")

    assert {:refuse, _} =
             Events.decide(
               ev("os_identity", "erlang:system_info/1", %{"key" => "version"}),
               ctx,
               "pkg"
             )

    # A path module as first frame does not cover a system_info read.
    assert {:refuse, _} =
             Events.decide(
               ev("os_identity", "erlang:system_info/1", %{"key" => "wordsize"},
                 first: {"filename", "split", 1}
               ),
               ctx,
               "pkg"
             )
  end

  defp epp(mfa, arg, bottom \\ %{"module" => "epp", "function" => "init_server", "arity" => 3}) do
    mfa
    |> then(&ev("os_identity", &1, arg, extent: "lineage", user: nil, first: "epp"))
    |> Map.put("bottom", bottom)
  end

  test "an epp server's predefined-macro reads are toolchain; its other reads are not",
       %{ctx: ctx} do
    assert :ignore = Events.decide(epp("erlang:system_info/1", %{"key" => "machine"}), ctx, "pkg")

    assert :ignore =
             Events.decide(epp("erlang:system_info/1", %{"key" => "otp_release"}), ctx, "pkg")

    assert :ignore = Events.decide(epp("os:type/0", %{}), ctx, "pkg")

    server = %{"module" => "epp", "function" => "server", "arity" => 3}
    assert :ignore = Events.decide(epp("os:type/0", %{}, server), ctx, "pkg")

    # Not an epp server: a user process, a cut stack, another bottom frame.
    # (`system_info(machine)` and `otp_release` are allowed everywhere since
    # item 5d, so `os:type/0` stands for the predefined-macro reads here: outside the
    # epp server it is a compile input, judge revision 17, never ignored.)
    for bottom <- [
          nil,
          %{"module" => "Elixir.Pkg", "function" => "f", "arity" => 0},
          %{"module" => "epp"}
        ] do
      assert {:observe, "os_type_reads", _} =
               Events.decide(epp("os:type/0", %{}, bottom), ctx, "pkg")
    end

    assert {:observe, "os_type_reads", _} =
             Events.decide(Map.delete(epp("os:type/0", %{}), "bottom"), ctx, "pkg")

    # A user frame on the stack is not the epp server's own work.
    framed = %{
      epp("os:type/0", %{})
      | "extent" => "frame",
        "user" => @user
    }

    assert {:observe, "os_type_reads", _} = Events.decide(framed, ctx, "pkg")

    # Every other read in that process stays user.
    assert {:refuse, _} =
             Events.decide(epp("erlang:system_info/1", %{"key" => "wordsize"}), ctx, "pkg")

    getenv = %{epp("os:getenv/1", %{"name" => "X"}) | "channel" => "env"}
    assert {:observe, "env_reads", %{"name" => "X"}} = Events.decide(getenv, ctx, "pkg")

    version = epp("os:version/0", %{})
    assert {:refuse, _} = Events.decide(version, ctx, "pkg")
  end

  # rebar3 fetching a plugin from Hex over TLS loads OTP's
  # `pubkey_os_cacerts`, whose `on_load/0` reads `os:type/0` only to decide
  # whether to load public_key's Windows NIF, on a process code_server runs
  # on-load functions in (the trace of otel_http 0.2.0).
  @cacerts_on_load %{"module" => "pubkey_os_cacerts", "function" => "on_load", "arity" => 0}

  defp on_load_read(overrides \\ %{}) do
    "os_identity"
    |> ev("os:type/0", %{}, user: Map.put(@cacerts_on_load, "file", "pubkey_os_cacerts.erl"))
    |> Map.merge(%{
      "first" => @cacerts_on_load,
      "caller" => @cacerts_on_load,
      "first_kind" => "toolchain",
      "caller_kind" => "toolchain",
      "bottom" => %{
        "module" => "code_server",
        "function" => "-schedule_on_load/4-fun-0-",
        "arity" => 1
      }
    })
    |> Map.merge(overrides)
  end

  test "OTP's pubkey_os_cacerts on-load OS read is ignored; the same read elsewhere is an input",
       %{ctx: ctx} do
    assert :ignore = Events.decide(on_load_read(), ctx, "pkg")
    # The second look at the same frame, taken while the load is pending.
    assert :ignore = Events.decide(on_load_read(%{"caller_kind" => "user"}), ctx, "pkg")

    for overrides <- [
          %{"first_kind" => "user"},
          %{"first_kind" => "none"},
          %{"bottom" => %{"module" => "Elixir.Pkg", "function" => "f", "arity" => 0}},
          %{"bottom" => nil},
          %{
            "first" => %{@cacerts_on_load | "function" => "get"},
            "caller" => %{@cacerts_on_load | "function" => "get"}
          },
          %{"caller" => %{"module" => "Elixir.Pkg", "function" => "f", "arity" => 0}}
        ] do
      assert {:observe, "os_type_reads", _} =
               Events.decide(on_load_read(overrides), ctx, "pkg"),
             inspect(overrides)
    end

    sysinfo = on_load_read(%{"mfa" => "erlang:system_info/1", "arg" => %{"key" => "os_type"}})
    assert {:observe, "os_type_reads", _} = Events.decide(sysinfo, ctx, "pkg")
  end

  @big_int %{"module" => "erlang", "function" => "big_binary_to_int", "arity" => 2}

  defp wordsize(key, caller) do
    event = ev("os_identity", "erlang:system_info/1", %{"key" => key}, first: "erlang")
    if caller == :none, do: event, else: Map.put(event, "caller", caller)
  end

  test "OTP's big integer conversion may read the word size; nothing else may", %{ctx: ctx} do
    assert :ignore = Events.decide(wordsize("wordsize", @big_int), ctx, "pkg")

    for caller <- [
          nil,
          :none,
          %{"module" => "Elixir.Pkg", "function" => "f", "arity" => 0},
          %{"module" => "erlang", "function" => "binary_to_integer", "arity" => 1},
          %{"module" => "erlang", "function" => "big_binary_to_int", "arity" => 3},
          %{"module" => "Elixir.Pkg", "function" => "big_binary_to_int", "arity" => 2}
        ] do
      assert {:refuse, "compile-time host read: erlang:system_info/1" <> _} =
               Events.decide(wordsize("wordsize", caller), ctx, "pkg"),
             inspect(caller)
    end

    for key <- ["version", "system_architecture"] do
      assert {:refuse, _} = Events.decide(wordsize(key, @big_int), ctx, "pkg"), key
    end

    assert {:observe, "os_type_reads", %{"scope" => "full"}} =
             Events.decide(wordsize("os_type", @big_int), ctx, "pkg")

    assert {:observe, "endian_reads", _} =
             Events.decide(wordsize("endian", @big_int), ctx, "pkg")

    other = %{wordsize("wordsize", @big_int) | "mfa" => "os:version/0", "arg" => %{}}
    assert {:refuse, _} = Events.decide(other, ctx, "pkg")
  end

  test "a stack without a user frame names its extent", %{ctx: ctx} do
    assert {:refuse,
            "compile-time host read: os:cmd/1 (truncated stack, first frame Elixir.Macro)"} =
             Events.decide(
               ev("programs", "os:cmd/1", %{"cmd" => "x"},
                 user: nil,
                 extent: "truncated",
                 first: "Elixir.Macro"
               ),
               ctx,
               "pkg"
             )
  end

  test "host channels refuse: env, programs, network, crypto, native loading", %{ctx: ctx} do
    for {channel, mfa} <- [
          {"env", "init:get_argument/1"},
          {"programs", "os:cmd/1"},
          {"network", "inet:gethostname/0"},
          {"crypto", "crypto:info_lib/0"},
          {"native", "erlang:load_nif/2"}
        ] do
      assert {:refuse, "compile-time host read: " <> _} =
               Events.decide(ev(channel, mfa, %{}), ctx, "pkg")
    end
  end

  # The tracer records a RAM file's open without its contents, which it
  # used to take for a path: a read is still the host read it was then, a
  # write the write outside ebin, now saying so.
  test "an open of a RAM file refuses as before, without its contents", %{ctx: ctx} do
    assert {:refuse, "compile-time host read: file:open/2 (an in-memory file) in " <> _} =
             Events.decide(ev("file_read", "file:open/2", %{"ram" => true}), ctx, "pkg")

    assert {:refuse, "compile-time write outside ebin: file:open/2 (an in-memory file)"} =
             Events.decide(ev("file_write", "file:open/2", %{"ram" => true}), ctx, "pkg")
  end

  # Inside a dependency's mix.exs a RAM read goes to R4 as every read does;
  # a RAM write is a write, which R4 never allows. So is a `prim_file:open/2`
  # with `ram` (the tracer records it as the real write it is).
  test "a RAM open in mix.exs: a read goes to R4, a write refuses", %{ctx: ctx, pkg: pkg} do
    read = in_mix_exs(ev("file_read", "file:open/2", %{"ram" => true}), pkg, 4)

    assert {:observe, "mix_exs_allowed", %{"mfa" => "file:open/2", "line" => 4}} =
             Events.decide(read, ctx, "pkg")

    assert {:refuse, "compile-time host read in mix.exs: file:open/2 sets elixirc_options" <> _} =
             Events.decide(put_in(read, ["user", "line"], 5), ctx, "pkg")

    write = in_mix_exs(ev("file_write", "file:open/2", %{"ram" => true}), pkg, 4)

    assert {:refuse, "compile-time write outside ebin: file:open/2 (an in-memory file)"} =
             Events.decide(write, ctx, "pkg")

    {:file_write, arg} =
      :ncc_tracer_channels.classify(:prim_file, :open, ["/etc/x", [:write, :ram]])

    arg = Map.new(arg, fn {k, v} -> {Atom.to_string(k), v} end)
    host = in_mix_exs(ev("file_write", "prim_file:open/2", arg), pkg, 4)

    assert {:refuse, "compile-time write outside ebin: prim_file:open/2 /etc/x"} =
             Events.decide(host, ctx, "pkg")
  end

  test "an unjudged stack, an unknown channel or a malformed event could not be judged",
       %{ctx: ctx} do
    assert {:unjudged, "portability could not be judged" <> _} =
             Events.decide(
               ev("config", "application:get_env/2", %{}, extent: "unjudged"),
               ctx,
               "pkg"
             )

    assert {:unjudged, _} =
             Events.decide(ev("os_identity", "os:type/0", %{}, extent: "sideways"), ctx, "pkg")

    assert {:unjudged, _} = Events.decide(ev("unclassified", "x:y/0", %{}), ctx, "pkg")
    assert {:unjudged, _} = Events.decide(ev("teleport", "x:y/0", %{}), ctx, "pkg")
    assert {:unjudged, _} = Events.decide(ev("file_read", "file:read_file/1", nil), ctx, "pkg")
    assert {:unjudged, _} = Events.decide(%{ev("env", nil, %{}) | "mfa" => 7}, ctx, "pkg")
    assert {:unjudged, _} = Events.decide(%{"channel" => "env"}, ctx, "pkg")
    assert {:unjudged, _} = Events.decide(:not_a_map, ctx, "pkg")

    # Even where a rule would ignore the call.
    assert {:unjudged, _} =
             Events.decide(
               ev("os_identity", "os:type/0", %{},
                 first: {"Elixir.Path", "major_os_type", 0},
                 extent: "unjudged"
               ),
               ctx,
               "pkg"
             )

    # A forged tracer request is written unjudged.
    assert {:unjudged, _} =
             Events.decide(
               ev("integrity", "ncc_tracer:forged_request", %{}, extent: "unjudged", user: nil),
               ctx,
               "pkg"
             )
  end

  test "integrity refuses with its own prefix; config and Elixir version are observed",
       %{ctx: ctx} do
    assert {:refuse, "compile-time tracing or system flag: dbg:stop/0"} =
             Events.decide(ev("integrity", "dbg:stop/0", %{}), ctx, "pkg")

    assert {:observe, "config_reads", %{"mfa" => "application:get_env/2"}} =
             Events.decide(
               ev("config", "application:get_env/2", %{"app" => "fx", "key" => "k"}),
               ctx,
               "pkg"
             )

    assert {:observe, "elixir_version",
            %{"mfa" => "System.version/0", "module" => "Elixir.Pkg", "line" => 3}} =
             Events.decide(ev("elixir_version", "System.version/0", %{}), ctx, "pkg")
  end

  test "every integrity event refuses, in any window and inside mix.exs", %{ctx: ctx, pkg: pkg} do
    for {mfa, arg} <- [
          {"erlang:process_info/2", %{"item" => "backtrace"}},
          {"erlang:process_info/2", %{"item" => "messages"}},
          {"erlang:process_info/2", %{"item" => "{dictionary,k}"}},
          {"erlang:process_info/1", %{"item" => "all"}},
          {"trace:function/4", %{}},
          {"erts_internal:trace_session_destroy/1", %{}},
          {"erlang:system_flag/2", %{"flag" => "backtrace_depth"}},
          {"code:unstick_mod/1", %{}},
          {"ncc_tracer:finish/2", %{}}
        ],
        owner <- ["pkg", "other", :outside, :quiet] do
      assert {:refuse, "compile-time tracing or system flag: " <> ^mfa} =
               Events.decide(ev("integrity", mfa, arg), ctx, owner)
    end

    # R4 never allows one: it judges host observations, not tampering.
    event = in_mix_exs(ev("integrity", "dbg:stop/0", %{}), pkg, 4)

    assert {:refuse, "compile-time tracing or system flag: dbg:stop/0"} =
             Events.decide(event, ctx, "pkg")
  end

  test "install locations: closure and OTP apps pass, others refuse", %{ctx: ctx} do
    lib = fn arg -> ev("install", "code:lib_dir/1", arg) end

    assert :ignore =
             Events.decide(
               lib.(%{"what" => "lib_dir", "app" => "pkg", "toolchain_app" => false}),
               ctx,
               "pkg"
             )

    assert :ignore =
             Events.decide(
               lib.(%{"what" => "priv_dir", "app" => "kernel", "toolchain_app" => true}),
               ctx,
               "pkg"
             )

    assert {:refuse, _} =
             Events.decide(
               lib.(%{"what" => "lib_dir", "app" => "other", "toolchain_app" => false}),
               ctx,
               "pkg"
             )

    assert :ignore = Events.decide(lib.(%{"what" => "lib_dir", "app" => "pkg"}), ctx, "pkg")
    assert {:refuse, _} = Events.decide(lib.(%{"what" => "lib_dir"}), ctx, "pkg")

    assert {:refuse, _} =
             Events.decide(ev("install", "code:root_dir/0", %{"what" => "root_dir"}), ctx, "pkg")

    assert {:refuse, _} =
             Events.decide(ev("install", "code:get_path/0", %{"what" => "get_path"}), ctx, "pkg")

    assert {:refuse, _} =
             Events.decide(
               ev("install", "application:loaded_applications/0", %{
                 "what" => "loaded_applications"
               }),
               ctx,
               "pkg"
             )
  end

  # The code path read code:where_is_file/1 makes for a file that is no
  # beam or .app, and code:all_available/0, refuse as host reads, but for
  # two toolchain callers: Record.extract/2's `from:` lookup, whose file
  # is read next and judged as a read, and the type checker formatting an
  # undefined-module warning's hint, whose text reaches only its warnings.
  test "code path reads: where_is_file and all_available", %{ctx: ctx} do
    where = fn first, kind ->
      "install"
      |> ev("code:where_is_file/1", %{"what" => "where_is_file", "file" => "src/x.hrl"},
        first: first
      )
      |> Map.put("first_kind", kind)
    end

    extractor = {"Elixir.Record.Extractor", "from_file", 1}
    assert :ignore = Events.decide(where.(extractor, "toolchain"), ctx, "pkg")
    assert {:refuse, _} = Events.decide(where.(extractor, "user"), ctx, "pkg")

    assert {:refuse, _} =
             Events.decide(where.({"Elixir.Record.Extractor", "x", 1}, "toolchain"), ctx, "pkg")

    assert {:refuse, _} = Events.decide(where.("Elixir.Pkg", "user"), ctx, "pkg")

    all = fn checker ->
      ev("install", "code:all_available/0", %{"what" => "all_available", "checker" => checker},
        first: {"Elixir.UndefinedFunctionError", "hint_for_missing_module", 3}
      )
    end

    assert :ignore = Events.decide(all.(true), ctx, "pkg")
    assert {:refuse, _} = Events.decide(all.(false), ctx, "pkg")

    assert {:refuse, _} =
             Events.decide(Map.update!(all.(true), "arg", &Map.delete(&1, "checker")), ctx, "pkg")

    nested = %{ctx | nested: %{"pkg" => "Elixir.Code:with_diagnostics/2"}}
    assert {:refuse, why} = Events.decide(all.(true), nested, "pkg")
    assert why =~ "nested compile (Elixir.Code:with_diagnostics/2)"
  end

  test "file reads resolve against the window's dependency", %{ctx: ctx} do
    assert :ignore =
             Events.decide(
               ev("file_read", "file:read_file/1", %{"path" => "README.md"}),
               ctx,
               "pkg"
             )

    assert :ignore =
             Events.decide(ev("file_read", "file:get_cwd/0", %{"cwd" => true}), ctx, "pkg")

    assert {:refuse, _} =
             Events.decide(ev("file_read", "file:get_cwd/0", %{"cwd" => true}), ctx, :outside)

    assert {:refuse, _} =
             Events.decide(
               ev("file_read", "file:read_file/1", %{"path" => "README.md"}),
               ctx,
               :outside
             )

    assert {:refuse, _} =
             Events.decide(ev("file_read", "file:read_file/1", %{"path" => nil}), ctx, "pkg")

    assert {:refuse, _} =
             Events.decide(
               ev("file_read", "file:read_file/1", %{"path" => "../../mix.exs"}),
               ctx,
               "pkg"
             )

    assert {:refuse,
            "compile-time host read: file:read_file/1 /etc/hosts in Pkg.f/0 (lib/pkg.ex:3)"} =
             Events.decide(
               ev("file_read", "file:read_file/1", %{"path" => "/etc/hosts"}),
               ctx,
               "pkg"
             )
  end

  test "after a user set_cwd, the window has no cwd to read or resolve against",
       %{dir: dir, proj: proj, pkg: pkg} do
    cd = ev("cwd", "file:set_cwd/1", %{"path" => "/tmp"})
    ctx = build(dir, proj, report(dir, proj, pkg, [cd]))

    assert {:refuse, _} =
             Events.decide(ev("file_read", "file:get_cwd/0", %{"cwd" => true}), ctx, "pkg")

    assert {:refuse, _} =
             Events.decide(
               ev("file_read", "file:read_file/1", %{"path" => "README.md"}),
               ctx,
               "pkg"
             )
  end

  test "a user set_cwd refuses, wherever it happens", %{ctx: ctx, pkg: pkg} do
    for {mfa, owner} <- [
          {"file:set_cwd/1", "pkg"},
          {"prim_file:set_cwd/1", "other"},
          {"file:set_cwd/1", :outside}
        ] do
      assert {:refuse, "compile-time host read: " <> rest} =
               Events.decide(ev("cwd", mfa, %{"path" => "/tmp"}), ctx, owner)

      assert rest =~ mfa
    end

    event = in_mix_exs(ev("cwd", "file:set_cwd/1", %{"path" => "/tmp"}), pkg, 4)

    assert {:refuse, "compile-time host read: file:set_cwd/1" <> _} =
             Events.decide(event, ctx, "pkg")
  end

  test "writes are allowed only into the window's own ebin", %{ctx: ctx, proj: proj, pkg: pkg} do
    own = Path.join(proj, "_build/host/lib/pkg/ebin/extra.txt")
    colocated = Path.join(proj, "_build/host/phoenix-colocated/pkg")

    assert :ignore =
             Events.decide(ev("file_write", "file:write_file/3", %{"path" => own}), ctx, "pkg")

    assert {:refuse, "compile-time write outside ebin: file:make_dir/1 " <> path} =
             Events.decide(
               ev("file_write", "file:make_dir/1", %{"path" => colocated}),
               ctx,
               "pkg"
             )

    assert path =~ "phoenix-colocated/pkg"

    assert {:refuse, _} =
             Events.decide(ev("file_write", "file:write_file/3", %{"path" => own}), ctx, :outside)

    assert {:refuse, _} =
             Events.decide(ev("file_write", "file:write_file/3", %{"path" => nil}), ctx, "pkg")

    assert {:refuse, "compile-time host read: " <> _} =
             Events.decide(
               ev("file_write", "file:copy/2", %{
                 "path" => own,
                 "from" => "/etc/hosts",
                 "from_kind" => "read"
               }),
               ctx,
               "pkg"
             )

    assert :ignore =
             Events.decide(
               ev("file_write", "file:copy/2", %{
                 "path" => own,
                 "from" => "README.md",
                 "from_kind" => "read"
               }),
               ctx,
               "pkg"
             )

    # A rename moves its source: both ends must be writable.
    assert {:refuse, "compile-time write outside ebin: file:rename/2 " <> _} =
             Events.decide(
               ev("file_write", "file:rename/2", %{
                 "path" => own,
                 "from" => Path.join(pkg, "README.md"),
                 "from_kind" => "write"
               }),
               ctx,
               "pkg"
             )

    # A write in mix.exs is not an observation R4 could allow.
    event = in_mix_exs(ev("file_write", "file:write_file/3", %{"path" => colocated}), pkg, 4)
    assert {:refuse, "compile-time write outside ebin: " <> _} = Events.decide(event, ctx, "pkg")
  end

  test "a link refuses even inside the window's own ebin", %{ctx: ctx, proj: proj} do
    own = Path.join(proj, "_build/host/lib/pkg/ebin/link")

    for mfa <-
          ~w(file:make_symlink/2 file:make_link/2 prim_file:make_symlink/2 prim_file:make_link/2) do
      assert {:refuse, "compile-time write outside ebin: " <> rest} =
               Events.decide(ev("file_write", mfa, %{"path" => own}), ctx, "pkg")

      assert rest =~ mfa
      assert rest =~ "link"
    end
  end

  # Judge revision 21: the package's own compile may write into its own build
  # priv, observed with the refusal it was before (the judge allows it only
  # when a second build reproduces that priv), and nowhere else.
  test "the package's own compile writing into its own build priv is observed", %{
    ctx: ctx,
    proj: proj,
    pkg: pkg
  } do
    file = Path.join(proj, "_build/host/lib/pkg/priv/assets/a.tar.gz")

    assert {:observe, "priv_writes", item} =
             Events.decide(ev("file_write", "file:open/2", %{"path" => file}), ctx, "pkg")

    assert item["paths"] == ["assets/a.tar.gz"]
    assert item["written"] == "assets/a.tar.gz"
    assert "compile-time write outside ebin: file:open/2 " <> _ = item["refusal"]

    dir = Path.join(proj, "_build/host/lib/pkg/priv/assets")

    assert {:observe, "priv_writes", %{"paths" => ["assets"], "written" => nil}} =
             Events.decide(ev("file_write", "file:make_dir/1", %{"path" => dir}), ctx, "pkg")

    assert {:observe, "priv_writes", %{"written" => nil}} =
             Events.decide(ev("file_write", "file:delete/1", %{"path" => file}), ctx, "pkg")

    # A copy's source is a read first.
    assert {:refuse, "compile-time host read: " <> _} =
             Events.decide(
               ev("file_write", "file:copy/2", %{
                 "path" => file,
                 "from" => "/etc/hosts",
                 "from_kind" => "read"
               }),
               ctx,
               "pkg"
             )

    assert {:observe, "priv_writes", %{"written" => "assets/a.tar.gz"}} =
             Events.decide(
               ev("file_write", "file:copy/2", %{
                 "path" => file,
                 "from" => Path.join(pkg, "README.md"),
                 "from_kind" => "read"
               }),
               ctx,
               "pkg"
             )

    # Never from the package's mix.exs, outside its window or for another app.
    event = in_mix_exs(ev("file_write", "file:write_file/3", %{"path" => file}), pkg, 4)
    assert {:refuse, "compile-time write outside ebin: " <> _} = Events.decide(event, ctx, "pkg")

    for owner <- ["other", :outside, :quiet] do
      assert {:refuse, "compile-time write outside ebin: " <> _} =
               Events.decide(ev("file_write", "file:open/2", %{"path" => file}), ctx, owner)
    end

    # The source tree's priv is no build priv.
    assert {:refuse, "compile-time write outside ebin: " <> _} =
             Events.decide(
               ev("file_write", "file:open/2", %{"path" => Path.join(pkg, "priv/a")}),
               ctx,
               "pkg"
             )
  end

  test "another closure app's compile writing into the package's priv refuses",
       %{dir: dir, proj: proj, pkg: pkg} do
    user = Path.join([proj, "deps", "user"])
    File.mkdir_p!(Path.join(user, "lib"))
    report = report(dir, proj, pkg, [])

    dependent = %{
      "app" => "user",
      "dest" => user,
      "build" => Path.join(proj, "_build/host/lib/user"),
      "manager" => "mix",
      "children" => ["pkg"]
    }

    report = %{report | closure: Map.update!(report.closure, "deps", &(&1 ++ [dependent]))}

    file = Path.join(proj, "_build/host/lib/pkg/priv/assets/User/a.tar.gz")
    event = ev("file_write", "file:open/2", %{"path" => file})

    # Judged for the package: the dependent's window is not the package's.
    ctx = build(dir, proj, report)
    assert {:observe, "priv_writes", _} = Events.decide(event, ctx, "pkg")
    assert {:refuse, "compile-time write outside ebin: " <> _} = Events.decide(event, ctx, "user")

    # Judged for the dependent: the package is a dependency, whose priv the
    # dependent's own compile may never write.
    ctx = %{ctx | package: "user"}
    assert {:refuse, "compile-time write outside ebin: " <> _} = Events.decide(event, ctx, "user")
    assert {:refuse, "compile-time write outside ebin: " <> _} = Events.decide(event, ctx, "pkg")
  end

  test "a build priv Mix linked to the package's source priv is not its own",
       %{dir: dir, proj: proj, pkg: pkg} do
    File.mkdir_p!(Path.join(pkg, "priv"))
    :ok = File.ln_s(Path.join(pkg, "priv"), Path.join(proj, "_build/host/lib/pkg/priv"))
    ctx = build(dir, proj, report(dir, proj, pkg, []))
    file = Path.join(proj, "_build/host/lib/pkg/priv/a")

    assert {:refuse, "compile-time write outside ebin: " <> _} =
             Events.decide(ev("file_write", "file:open/2", %{"path" => file}), ctx, "pkg")
  end

  # Elixir 1.20's File.mkdir_p/1 tries :file.make_dir/1 on every directory
  # from / down and asks File.dir?/1 of each one that is there: above the
  # package's own priv those are probes of directories every build has,
  # observed (allowed only with the second build), when the toolchain's own
  # File and elixir_utils make them; anything else stays a refusal.
  test "File.mkdir_p/1's probes above the package's own priv are observed", %{
    ctx: ctx,
    proj: proj
  } do
    mkdir_p = %{"module" => "Elixir.File", "function" => "do_mkdir_p", "arity" => 1}
    type = %{"module" => "elixir_utils", "function" => "read_file_type", "arity" => 2}
    above = [proj, Path.join(proj, "_build/host"), Path.join(proj, "_build/host/lib/pkg")]

    for path <- above do
      make_dir =
        ev("file_write", "file:make_dir/1", %{"path" => path})
        |> Map.merge(%{"caller" => mkdir_p, "caller_kind" => "toolchain"})

      assert {:observe, "priv_probes", %{"refusal" => "compile-time write outside ebin: " <> _}} =
               Events.decide(make_dir, ctx, "pkg")

      dir? =
        ev("file_read", "file:read_file_info/2", %{"path" => path})
        |> Map.merge(%{"caller" => type, "caller_kind" => "toolchain"})

      expected = if path == Path.join(proj, "_build/host/lib/pkg"), do: :ignore, else: :probe

      case expected do
        :ignore ->
          assert :ignore = Events.decide(dir?, ctx, "pkg")

        :probe ->
          assert {:observe, "priv_probes", %{"refusal" => "compile-time host read: " <> _}} =
                   Events.decide(dir?, ctx, "pkg")
      end

      # Another window, another caller, a package's own module of that name.
      for {event, owner} <- [
            {make_dir, "other"},
            {make_dir, :outside},
            {%{make_dir | "caller_kind" => "user"}, "pkg"},
            {Map.delete(make_dir, "caller"), "pkg"},
            {Map.put(dir?, "caller", mkdir_p), "pkg"},
            {%{dir? | "caller_kind" => "user"}, "pkg"},
            {%{dir? | "mfa" => "file:read_file_info/1"}, "pkg"}
          ],
          expected == :probe or event["channel"] == "file_write" do
        assert {:refuse, _} = Events.decide(event, ctx, owner), inspect({event, owner})
      end
    end

    # Not above the package's own priv: a sibling, the file system root,
    # a path below priv's parent that is not on the way to it.
    for path <- ["/", Path.join(proj, "deps"), Path.join(proj, "_build/host/lib/other")] do
      make_dir =
        ev("file_write", "file:make_dir/1", %{"path" => path})
        |> Map.merge(%{"caller" => mkdir_p, "caller_kind" => "toolchain"})

      assert {:refuse, _} = Events.decide(make_dir, ctx, "pkg")

      dir? =
        ev("file_read", "file:read_file_info/2", %{"path" => path})
        |> Map.merge(%{"caller" => type, "caller_kind" => "toolchain"})

      assert {:refuse, _} = Events.decide(dir?, ctx, "pkg")
    end
  end

  test "calls into a native dependency refuse in the package's window and outside every window",
       %{ctx: ctx} do
    event = ev("native_closure", "nat:open/1", %{"module" => "nat"})

    assert {:refuse, "calls natively built dependency at compile time: nat:open/1"} =
             Events.decide(event, ctx, "pkg")

    assert {:refuse, _} = Events.decide(event, ctx, :outside)
    assert {:observe, "native_calls", _} = Events.decide(event, ctx, "other")
  end

  describe "a read of a natively built dependency's ebin (judge revision 15)" do
    # `nat`, natively built, with a beam in its ebin and a file in its
    # build dir's priv.
    defp nat_ctx(dir, proj, pkg) do
      nat_build = Path.join(proj, "_build/host/lib/nat")
      File.mkdir_p!(Path.join(nat_build, "ebin"))
      File.mkdir_p!(Path.join(nat_build, "priv"))
      File.write!(Path.join(nat_build, "ebin/Elixir.Nat.beam"), "")
      File.write!(Path.join(nat_build, "priv/nat.so"), "")
      File.mkdir_p!(Path.join(proj, "deps/nat/lib"))

      nat = %{
        "app" => "nat",
        "dest" => Path.join(proj, "deps/nat"),
        "build" => nat_build,
        "manager" => "mix",
        "children" => []
      }

      report = report(dir, proj, pkg, [])
      report = update_in(report.closure["deps"], &[nat | &1])
      {build(dir, proj, report, native: ["nat"]), nat_build}
    end

    test "is observed for the judge with the refusal it would be", %{
      dir: dir,
      proj: proj,
      pkg: pkg
    } do
      {ctx, nat_build} = nat_ctx(dir, proj, pkg)
      beam = Path.join(nat_build, "ebin/Elixir.Nat.beam")

      for path <- [beam, Path.join(nat_build, "ebin")], owner <- ["pkg", :outside] do
        event = ev("file_read", "prim_file:read_file/1", %{"path" => path})

        assert {:observe, "native_beam_reads", %{"app" => "nat", "ts" => 50} = item} =
                 Events.decide(event, ctx, owner)

        assert item["refusal"] ==
                 "compile-time host read: prim_file:read_file/1 #{path}" <>
                   " in Pkg.f/0 (lib/pkg.ex:3)"
      end
    end

    test "anything else under its build dir still refuses", %{dir: dir, proj: proj, pkg: pkg} do
      {ctx, nat_build} = nat_ctx(dir, proj, pkg)

      for path <- [Path.join(nat_build, "priv/nat.so"), nat_build, Path.join(nat_build, ".mix")] do
        event = ev("file_read", "prim_file:read_file/1", %{"path" => path})
        assert {:refuse, "compile-time host read: " <> _} = Events.decide(event, ctx, "pkg")
      end
    end

    test "a non-native dependency's ebin stays plainly readable", %{
      dir: dir,
      proj: proj,
      pkg: pkg
    } do
      {ctx, _nat_build} = nat_ctx(dir, proj, pkg)
      path = Path.join(proj, "_build/host/lib/pkg/ebin/Elixir.Pkg.beam")
      event = ev("file_read", "prim_file:read_file/1", %{"path" => path})
      assert :ignore = Events.decide(event, ctx, :outside)
    end
  end

  test "a refusal inside mix.exs goes to R4", %{ctx: ctx, pkg: pkg} do
    deps_read = in_mix_exs(ev("network", "inet:gethostname/0", %{}), pkg, 4)
    opts_read = put_in(deps_read, ["user", "line"], 5)

    assert {:observe, "mix_exs_allowed", %{"mfa" => "inet:gethostname/0", "line" => 4}} =
             Events.decide(deps_read, ctx, "pkg")

    assert {:refuse,
            "compile-time host read in mix.exs: inet:gethostname/0 sets elixirc_options" <> _} =
             Events.decide(opts_read, ctx, "pkg")

    # A precomputed slice is used instead of reading the file again.
    slices = Events.mix_exs_slices(ctx, [{"pkg", deps_read}])
    assert [{_path, {:ok, _}}] = Map.to_list(slices)

    assert {:observe, "mix_exs_allowed", _} = Events.decide(deps_read, ctx, "pkg", slices)

    # A frame without a line cannot be sliced.
    no_line = put_in(deps_read, ["user", "line"], nil)

    assert {:refuse, "compile-time host read: inet:gethostname/0" <> _} =
             Events.decide(no_line, ctx, "pkg")

    # Native loading runs code the trace cannot follow: never R4.
    nif = in_mix_exs(ev("native", "erlang:load_nif/2", %{"path" => "x"}), pkg, 4)

    assert {:refuse, "compile-time host read: erlang:load_nif/2" <> _} =
             Events.decide(nif, ctx, "pkg")
  end

  test "running a program from mix.exs refuses outright; a lookup goes to R4",
       %{ctx: ctx, pkg: pkg} do
    for {mfa, arg} <- [
          {"os:cmd/1", %{"cmd" => "git describe"}},
          {"os:cmd/2", %{"cmd" => "git describe"}},
          {"erlang:open_port/2", %{"port" => "{spawn,\"git describe\"}"}},
          {"erlang:open_port/2", %{"port" => "{spawn_executable,\"/usr/bin/git\"}"}}
        ] do
      event = in_mix_exs(ev("programs", mfa, arg), pkg, 4)
      assert {:refuse, "compile-time host read: " <> rest} = Events.decide(event, ctx, "pkg")
      assert String.starts_with?(rest, mfa)
    end

    lookup = in_mix_exs(ev("programs", "os:find_executable/1", %{"name" => "git"}), pkg, 4)
    assert {:observe, "mix_exs_allowed", _} = Events.decide(lookup, ctx, "pkg")

    assert {:refuse, "compile-time host read in mix.exs: os:find_executable/1 sets " <> _} =
             Events.decide(put_in(lookup, ["user", "line"], 5), ctx, "pkg")
  end

  test "an env read in mix.exs is an input; R4 marks one that reaches no compile key",
       %{ctx: ctx, pkg: pkg} do
    deps_read = in_mix_exs(ev("env", "os:getenv/1", %{"name" => "XV"}), pkg, 4)

    assert {:observe, "env_reads", %{"slice_allowed" => true}} =
             Events.decide(deps_read, ctx, "pkg")

    opts_read = put_in(deps_read, ["user", "line"], 5)

    assert {:observe, "env_reads", %{"slice_allowed" => false}} =
             Events.decide(opts_read, ctx, "pkg")

    assert :ignore = Events.decide(ev("env", "os:getenv/2", %{"name" => "X"}), ctx, "pkg")

    assert {:observe, "env_reads", %{"all" => true}} =
             Events.decide(ev("env", "os:env/0", %{}), ctx, "pkg")
  end

  test "init arguments are still a host read", %{ctx: ctx} do
    for mfa <- ~w(init:get_argument/1 init:get_arguments/0 init:get_plain_arguments/0) do
      assert {:refuse, "compile-time host read: " <> rest} =
               Events.decide(ev("env", mfa, %{}), ctx, "pkg")

      assert String.starts_with?(rest, mfa)
    end
  end

  test "a mix.exs the slice cannot read refuses", %{ctx: ctx, pkg: pkg} do
    File.write!(Path.join(pkg, "mix.exs"), String.duplicate("#", 300 * 1024))
    event = in_mix_exs(ev("network", "inet:gethostname/0", %{}), pkg, 4)

    assert {:refuse, "compile-time host read in mix.exs: inet:gethostname/0 " <> _} =
             Events.decide(event, ctx, "pkg")

    File.rm!(Path.join(pkg, "mix.exs"))

    assert {:refuse, "compile-time host read in mix.exs: " <> _} =
             Events.decide(event, ctx, "pkg")
  end

  test "the wrapper project's own mix.exs is never held against anyone", %{ctx: ctx} do
    assert :ignore = Events.decide(ev("env", "os:getenv/1", %{}), ctx, :wrapper)
  end

  test "config and Elixir-version observations keep who made the read", %{ctx: ctx} do
    arg = %{"app" => "fx", "app_name" => "fx", "key_name" => "k", "atoms" => true}

    event =
      "config"
      |> ev("application:get_env/2", arg, first: "Elixir.Logger")
      |> Map.put("first_kind", "toolchain")

    assert {:observe, "config_reads",
            %{"first" => "Elixir.Logger", "first_kind" => "toolchain", "extent" => "frame"}} =
             Events.decide(event, ctx, "pkg")

    version = Map.put(ev("elixir_version", "System.version/0", %{}), "first_kind", "user")

    assert {:observe, "elixir_version",
            %{"first" => "Elixir.Pkg", "first_kind" => "user", "extent" => "frame"}} =
             Events.decide(version, ctx, "pkg")
  end

  test "an Elixir version read in a dependency's mix.exs goes to R4", %{ctx: ctx, pkg: pkg} do
    # Line 4 only picks deps, line 5 sets elixirc_options.
    deps_read = in_mix_exs(ev("elixir_version", "System.version/0", %{}), pkg, 4)
    opts_read = in_mix_exs(ev("elixir_version", "System.version/0", %{}), pkg, 5)

    assert :ignore = Events.decide(deps_read, ctx, "pkg")

    assert {:refuse,
            "compile-time Elixir patch dependence: System.version/0 sets elixirc_options" <> _} =
             Events.decide(opts_read, ctx, "pkg")

    slices = Events.mix_exs_slices(ctx, [{"pkg", opts_read}])

    assert {:refuse, "compile-time Elixir patch dependence: " <> _} =
             Events.decide(opts_read, ctx, "pkg", slices)
  end

  test "a direct, literal Version comparison in mix.exs is observed for the series rule",
       %{ctx: ctx, pkg: pkg} do
    File.write!(Path.join(pkg, "mix.exs"), """
    defmodule Pkg.MixProject do
      use Mix.Project
      def project, do: [app: :pkg, version: "1.0.0", deps: [], elixirc_options: opts() ++ raw()]
      defp opts, do: if(Version.match?(System.version(), "~> 1.15"), do: [a: 1], else: [])
      defp raw, do: [b: System.version()]
    end
    """)

    read = in_mix_exs(ev("elixir_version", "System.version/0", %{}), pkg, 4)

    call =
      in_mix_exs(
        ev("elixir_version", "Version.match?/2", %{
          "left" => ~s("1.19.5"),
          "right" => ~s("~> 1.15")
        }),
        pkg,
        4
      )

    for event <- [read, call] do
      assert {:observe, "elixir_version", %{"series" => true, "line" => 4} = item} =
               Events.decide(event, ctx, "pkg")

      assert item["mfa"] == event["mfa"]
    end

    # A read used any other way still refuses.
    raw = in_mix_exs(ev("elixir_version", "System.version/0", %{}), pkg, 5)

    assert {:refuse, "compile-time Elixir patch dependence: System.version/0" <> _} =
             Events.decide(raw, ctx, "pkg")
  end

  describe "mix_state (item 2's gap)" do
    # No mix.exs exemption: a literal read there is native by the static
    # scan already, so one the trace sees is one that scan could not.
    test "Mix.target refuses in code and in a dependency's mix.exs", %{ctx: ctx, pkg: pkg} do
      event = ev("mix_state", "Mix.target/0", %{"fun" => "target"})

      assert {:refuse, "compile-time host read: Mix.target/0 in Pkg.f/0 (lib/pkg.ex:3)"} =
               Events.decide(event, ctx, "pkg")

      assert {:refuse, "compile-time host read: Mix.target/0 in Pkg.MixProject.deps/0" <> _} =
               Events.decide(in_mix_exs(event, pkg, 3), ctx, "pkg")
    end

    test "Mix.Project's path functions are observed, never refused", %{ctx: ctx} do
      for fun <- ["build_path", "app_path", "compile_path"] do
        event = ev("mix_state", "Mix.Project.#{fun}/0", %{"fun" => fun})

        assert {:observe, "mix_project_paths", %{"mfa" => "Mix.Project." <> _}} =
                 Events.decide(event, ctx, "pkg")
      end
    end

    test "an unknown mix_state function could not be judged", %{ctx: ctx} do
      for arg <- [%{"fun" => "env"}, %{}] do
        assert {:unjudged, "portability could not be judged" <> _} =
                 Events.decide(ev("mix_state", "Mix.env/0", arg), ctx, "pkg")
      end
    end
  end

  describe "item 5a: OTP code loading" do
    test "flagged reads of OTP's own code loading are ignored", %{ctx: ctx} do
      link = ev("file_read", "prim_file:read_link/1", %{"path" => "/usr", "code_loading" => true})
      assert :ignore = Events.decide(link, ctx, "pkg")

      os =
        ev("os_identity", "erlang:system_info/1", %{"key" => "os_type", "code_loading" => true})

      assert :ignore = Events.decide(os, ctx, "pkg")
    end

    test "the same reads without the flag, other calls with it, and the beam read still refuse",
         %{ctx: ctx} do
      for event <- [
            ev("file_read", "prim_file:read_link/1", %{"path" => "/usr"}),
            ev("file_read", "file:read_link/1", %{"path" => "/usr", "code_loading" => true}),
            ev("file_read", "prim_file:read_link_all/1", %{
              "path" => "/usr",
              "code_loading" => true
            }),
            ev("file_read", "prim_file:read_file/1", %{
              "path" => "/usr/x.beam",
              "code_loading" => true
            }),
            ev("os_identity", "erlang:system_info/1", %{
              "key" => "nif_version",
              "code_loading" => true
            }),
            ev("os_identity", "os:version/0", %{"code_loading" => true}),
            # A flag that is not exactly `true` is no flag.
            ev("file_read", "prim_file:read_link/1", %{"path" => "/usr", "code_loading" => "true"})
          ] do
        assert {:refuse, "compile-time host read: " <> _} = Events.decide(event, ctx, "pkg"),
               inspect(event)
      end
    end

    test "get_cwd is never a code-loading read: the flag changes nothing", %{ctx: ctx} do
      for owner <- ["pkg", :outside] do
        plain = ev("file_read", "prim_file:get_cwd/0", %{"cwd" => true})
        flagged = ev("file_read", "prim_file:get_cwd/0", %{"cwd" => true, "code_loading" => true})
        assert Events.decide(flagged, ctx, owner) == Events.decide(plain, ctx, owner)
      end

      flagged = ev("file_read", "prim_file:get_cwd/0", %{"cwd" => true, "code_loading" => true})
      assert {:refuse, _} = Events.decide(flagged, ctx, :outside)
    end

    test "os_type read by erl_prim_loader's path helpers is path handling", %{ctx: ctx} do
      for {f, a} <- [{"pathtype", 1}, {"normalize", 2}, {"real_path", 4}] do
        event =
          ev("os_identity", "erlang:system_info/1", %{"key" => "os_type"},
            first: {"erl_prim_loader", f, a}
          )

        assert :ignore = Events.decide(event, ctx, "pkg"), f
      end

      # Not a path helper: a direct erl_prim_loader call's own frame, and any other key.
      for {first, key} <- [
            {{"erl_prim_loader", "read_file", 1}, "os_type"},
            {{"erl_prim_loader", "name_split", 2}, "os_type"},
            {{"erl_prim_loader", "pathtype", 1}, "nif_version"}
          ] do
        event = ev("os_identity", "erlang:system_info/1", %{"key" => key}, first: first)
        refute Events.decide(event, ctx, "pkg") == :ignore, inspect(first)
      end

      # The OS type itself, flagged or not, outside a path helper: a compile input.
      for event <- [
            ev("os_identity", "os:type/0", %{"code_loading" => true}),
            ev("os_identity", "erlang:system_info/1", %{"key" => "os_type"},
              first: {"erl_prim_loader", "read_file", 1}
            )
          ] do
        assert {:observe, "os_type_reads", %{"scope" => "full"}} =
                 Events.decide(event, ctx, "pkg")
      end
    end
  end

  describe "the OS type (judge revision 17)" do
    defp os_read(mfa, arg, caller, kind) do
      ev("os_identity", mfa, arg)
      |> Map.put("caller", caller)
      |> then(&if(kind == :absent, do: &1, else: Map.put(&1, "caller_kind", kind)))
    end

    @rm_rf %{
      "module" => "Elixir.File",
      "function" => "rm_rf",
      "arity" => 1,
      "file" => "lib/file.ex"
    }
    @os_type %{"module" => "os", "function" => "type", "arity" => 0, "file" => "os.erl"}

    test "a read is a compile input wherever and by whoever it is made", %{ctx: ctx} do
      for {mfa, arg} <- [{"os:type/0", %{}}, {"erlang:system_info/1", %{"key" => "os_type"}}],
          extent <- ~w(frame dispatcher truncated lineage),
          owner <- ["pkg", "dep", :outside] do
        event = ev("os_identity", mfa, arg, extent: extent)

        assert {:observe, "os_type_reads", %{"mfa" => ^mfa, "scope" => "full"}} =
                 Events.decide(event, ctx, owner),
               inspect({mfa, extent, owner})
      end
    end

    # kino: `File.rm_rf!/1` in `Kino.JS.__before_compile__/1`, whose
    # `{major, _} = :os.type()` keeps only the family.
    test "the toolchain's File.rm_rf/1 reaches the family alone", %{ctx: ctx} do
      assert {:observe, "os_type_reads", %{"scope" => "family"}} =
               Events.decide(os_read("os:type/0", %{}, @rm_rf, "toolchain"), ctx, "pkg")
    end

    test "OTP's os:type/0 reading system_info is covered by its own read", %{ctx: ctx} do
      assert {:observe, "os_type_reads", %{"scope" => "covered"}} =
               Events.decide(
                 os_read("erlang:system_info/1", %{"key" => "os_type"}, @os_type, "toolchain"),
                 ctx,
                 "pkg"
               )
    end

    # Fail closed: anything short of exactly those callers reaches the whole tuple.
    test "any other caller, or one not the toolchain's, reaches the whole tuple", %{ctx: ctx} do
      for {mfa, arg, caller} <- [
            {"os:type/0", %{}, @rm_rf},
            {"erlang:system_info/1", %{"key" => "os_type"}, @os_type}
          ],
          kind <- ["user", "none", "glue", nil, :absent] do
        assert {:observe, "os_type_reads", %{"scope" => "full"}} =
                 Events.decide(os_read(mfa, arg, caller, kind), ctx, "pkg"),
               inspect({mfa, kind})
      end

      for caller <- [
            %{@rm_rf | "function" => "rm_rf!"},
            %{@rm_rf | "arity" => 2},
            %{@rm_rf | "module" => "Elixir.Pkg.File"},
            %{"module" => "Elixir.Pkg", "function" => "f", "arity" => 0},
            @os_type,
            nil
          ] do
        assert {:observe, "os_type_reads", %{"scope" => "full"}} =
                 Events.decide(os_read("os:type/0", %{}, caller, "toolchain"), ctx, "pkg"),
               inspect(caller)
      end

      # The system_info read covered only below os:type/0 itself.
      for caller <- [@rm_rf, %{@os_type | "function" => "version"}, nil] do
        assert {:observe, "os_type_reads", %{"scope" => "full"}} =
                 Events.decide(
                   os_read("erlang:system_info/1", %{"key" => "os_type"}, caller, "toolchain"),
                   ctx,
                   "pkg"
                 ),
               inspect(caller)
      end
    end

    test "os:version/0 still refuses, wherever it is read", %{ctx: ctx} do
      assert {:refuse, "compile-time host read: os:version/0" <> _} =
               Events.decide(os_read("os:version/0", %{}, @rm_rf, "toolchain"), ctx, "pkg")
    end

    test "an epp server's own read and a path helper's are still ignored", %{ctx: ctx} do
      assert :ignore = Events.decide(epp("os:type/0", %{}), ctx, "pkg")

      assert :ignore =
               Events.decide(
                 ev("os_identity", "os:type/0", %{}, first: {"Elixir.Path", "major_os_type", 0}),
                 ctx,
                 "pkg"
               )
    end
  end

  describe "the type checker sizing its pool (schedulers_online)" do
    # A fresh `Module.ParallelChecker` (started by `get/0` for a module a
    # dependency's `mix.exs` or a nested compile defines) reads
    # `max(erlang:system_info(schedulers_online), 2)` in its init/1, in a
    # process the trace takes for the package's by lineage: inflex's,
    # gen_state_machine's and phoenix_pubsub's `mix.exs`, real traces.
    @pool %{
      "module" => "Elixir.Module.ParallelChecker",
      "function" => "-init/1-fun-2-",
      "arity" => 0,
      "file" => "lib/module/parallel_checker.ex",
      "line" => 571
    }
    @proc_lib %{
      "module" => "proc_lib",
      "function" => "init_p_do_apply",
      "arity" => 3,
      "file" => "proc_lib.erl",
      "line" => 333
    }
    @pool_reason "compile-time host read: erlang:system_info/1 (schedulers_online) " <>
                   "(lineage stack, first frame Elixir.Module.ParallelChecker)"

    defp pool_read(overrides \\ %{}) do
      Map.merge(
        %{
          "ts" => 50,
          "pid" => "<0.161.0>",
          "channel" => "os_identity",
          "mfa" => "erlang:system_info/1",
          "arg" => %{"key" => "schedulers_online"},
          "extent" => "lineage",
          "first" => @pool,
          "first_kind" => "toolchain",
          "caller" => @pool,
          "caller_kind" => "toolchain",
          "bottom" => @proc_lib,
          "user" => nil
        },
        overrides
      )
    end

    test "the checker's own pool size read is ignored, for every owner", %{ctx: ctx} do
      for owner <- ["pkg", "dep", :outside] do
        assert :ignore = Events.decide(pool_read(), ctx, owner), inspect(owner)
      end

      assert :ignore =
               Events.decide(pool_read(%{"first" => %{@pool | "line" => 563}}), ctx, "pkg")
    end

    # The same key from any other frame, stack or kind still refuses, with
    # the reason it always had.
    test "the same read made any other way still refuses", %{ctx: ctx} do
      assert {:refuse, @pool_reason} =
               Events.decide(pool_read(%{"first_kind" => "user"}), ctx, "pkg")

      for overrides <- [
            %{"first_kind" => "user"},
            %{"first_kind" => "glue"},
            %{"first_kind" => nil},
            %{"caller_kind" => "user"},
            %{"caller_kind" => nil},
            %{"first" => %{@pool | "function" => "-init/1-fun-1-"}},
            %{"first" => %{@pool | "function" => "init"}},
            %{"first" => %{@pool | "arity" => 1}},
            %{"first" => %{@pool | "module" => "Elixir.Pkg.ParallelChecker"}},
            %{"first" => %{@pool | "module" => "Elixir.Kernel.ParallelCompiler"}},
            %{"caller" => %{@pool | "function" => "init"}},
            %{"caller" => @user},
            %{"caller" => nil},
            %{"bottom" => %{@proc_lib | "function" => "init_p"}},
            %{"bottom" => @pool},
            %{"bottom" => nil},
            %{"extent" => "frame", "user" => @user},
            %{"extent" => "dispatcher"},
            %{"extent" => "truncated"},
            %{"user" => @user}
          ] do
        assert {:refuse, "compile-time host read: erlang:system_info/1 (schedulers_online)" <> _} =
                 Events.decide(pool_read(overrides), ctx, "pkg"),
               inspect(overrides)
      end

      for event <- [Map.delete(pool_read(), "bottom"), Map.delete(pool_read(), "caller")] do
        assert {:refuse, _} = Events.decide(event, ctx, "pkg")
      end
    end

    test "only the schedulers_online key", %{ctx: ctx} do
      for key <- ~w(schedulers logical_processors logical_processors_online cpu_topology) do
        assert {:refuse, reason} =
                 Events.decide(pool_read(%{"arg" => %{"key" => key}}), ctx, "pkg")

        assert reason =~ "compile-time host read: erlang:system_info/1 (#{key})", key
      end
    end

    # codepagex's module body: Task.async_stream/3 sizing its own pool, and a
    # module body asking for the count itself.
    test "a package's own pool size read refuses", %{ctx: ctx} do
      stream = %{
        "module" => "Elixir.Task.Supervised",
        "function" => "validate_stream_options",
        "arity" => 1
      }

      for first <- [stream, {"Elixir.System", "schedulers_online", 0}, "Elixir.Pkg"] do
        event =
          ev("os_identity", "erlang:system_info/1", %{"key" => "schedulers_online"},
            first:
              if(is_map(first),
                do: {first["module"], first["function"], first["arity"]},
                else: first
              )
          )

        assert {:refuse, "compile-time host read: erlang:system_info/1 (schedulers_online)" <> _} =
                 Events.decide(event, ctx, "pkg"),
               inspect(first)
      end
    end
  end

  describe "items 5c and 5d: system_info keys and reasons" do
    test "keys constant within an OTP major are allowed; host-dependent ones are not",
         %{ctx: ctx} do
      for key <- ~w(machine smp_support threads heap_type) do
        assert :ignore =
                 Events.decide(
                   ev("os_identity", "erlang:system_info/1", %{"key" => key}),
                   ctx,
                   "pkg"
                 ),
               key
      end

      for key <-
            ~w(version nif_version driver_version wordsize system_architecture) ++
              ["{allocator,sys_alloc}"] do
        assert {:refuse, reason} =
                 Events.decide(
                   ev("os_identity", "erlang:system_info/1", %{"key" => key}),
                   ctx,
                   "pkg"
                 )

        assert reason ==
                 "compile-time host read: erlang:system_info/1 (#{key}) in Pkg.f/0 (lib/pkg.ex:3)"
      end
    end

    test "the byte order is a compile input, wherever and however it is read", %{ctx: ctx} do
      # nx's `System.endianness/0` in a module body, and the same read with
      # every stack shape and owner: never a refusal. `CompileInputs` records
      # the builder's byte order and the client compares its own.
      for event <- [
            ev("os_identity", "erlang:system_info/1", %{"key" => "endian"}),
            ev("os_identity", "erlang:system_info/1", %{"key" => "endian"},
              first: {"Elixir.System", "endianness", 0}
            ),
            ev("os_identity", "erlang:system_info/1", %{"key" => "endian"},
              user: nil,
              extent: "lineage"
            ),
            ev("os_identity", "erlang:system_info/1", %{"key" => "endian", "code_loading" => true})
          ],
          owner <- ["pkg", "dep", :outside] do
        assert {:observe, "endian_reads", %{"mfa" => "erlang:system_info/1"}} =
                 Events.decide(event, ctx, owner),
               inspect({event, owner})
      end

      # Only the endian key: a tuple key that mentions it is not that read.
      assert {:refuse, _} =
               Events.decide(
                 ev("os_identity", "erlang:system_info/1", %{"key" => "{endian,big}"}),
                 ctx,
                 "pkg"
               )
    end

    test "a reason names the env var and the frame that made the call", %{ctx: ctx} do
      assert {:observe, "env_reads", %{"name" => "FX_FLAG", "file" => "lib/pkg.ex", "line" => 3}} =
               Events.decide(ev("env", "os:getenv/1", %{"name" => "FX_FLAG"}), ctx, "pkg")

      event =
        ev("os_identity", "erlang:system_info/1", %{"key" => "system_architecture"},
          first: {"Elixir.CCPrecompiler", "current_target", 0}
        )

      assert {:refuse, reason} = Events.decide(event, ctx, "pkg")

      assert reason ==
               "compile-time host read: erlang:system_info/1 (system_architecture) " <>
                 "via CCPrecompiler.current_target/0 in Pkg.f/0 (lib/pkg.ex:3)"

      # Item 5b: a wildcard through an untraced module is a read with no
      # path, refused (withdrawing), never could-not-judge.
      assert {:refuse,
              "compile-time host read: filelib:wildcard/2 in Pkg.f/0 (lib/pkg.ex:3)" = wild} =
               Events.decide(
                 ev("file_read", "filelib:wildcard/2", %{"module" => "my_mod"}),
                 ctx,
                 "pkg"
               )

      assert Compatibility.Portability.withdraws?(wild)

      # The prefix the portal withdraws on is unchanged.
      assert Compatibility.Portability.refusal?(reason)
      assert Compatibility.Portability.withdraws?(reason)
    end
  end

  test "env and config writes are observed, never refused", %{ctx: ctx} do
    put = ev("env_write", "os:putenv/2", %{"name" => "X", "value" => "v"})

    assert {:observe, "env_writes",
            %{"name" => "X", "value" => "v", "ts" => 50, "file" => "lib/pkg.ex"}} =
             Events.decide(put, ctx, "pkg")

    set =
      ev("config_write", "application:set_env/4", %{"app" => "a", "key" => "k", "value" => "v"})

    assert {:observe, "config_writes", %{"mfa" => "application:set_env/4"}} =
             Events.decide(set, ctx, "pkg")

    assert {:observe, "env_writes", _} = Events.decide(put, ctx, :outside)
  end

  # The members of pkg's tarball as they are on disk: the snapshot matched.
  defp matched_tree(pkg) do
    members =
      for rel <- ["README.md", "mix.exs"], into: %{} do
        sha = :crypto.hash(:sha256, File.read!(Path.join(pkg, rel)))
        {rel, Base.encode16(sha, case: :lower)}
      end

    %{"pkg" => {:ok, members}}
  end

  test "a read of a path absent from a matched tarball tree is the tree check's to decide",
       %{dir: dir, proj: proj, pkg: pkg} do
    report = report(dir, proj, pkg, [])
    ctx = build(dir, proj, report, trees: matched_tree(pkg))
    unchecked = build(dir, proj, report)

    # Line 5 sets elixirc_options, so the mix.exs slice alone would refuse.
    wildcard =
      in_mix_exs(
        ev("file_read", "file:list_dir/1", %{"path" => "guides", "listing" => true}),
        pkg,
        5
      )

    read =
      in_mix_exs(ev("file_read", "file:read_file_info/1", %{"path" => "guides/a.md"}), pkg, 5)

    absolute =
      in_mix_exs(
        ev("file_read", "file:read_file/1", %{"path" => Path.join(pkg, "edoc/x.md")}),
        pkg,
        5
      )

    for event <- [wildcard, read, absolute] do
      assert :ignore = Events.decide(event, ctx, "pkg")
      # No snapshot, no tree check: still a host read.
      assert {:refuse, _} = Events.decide(event, unchecked, "pkg")
    end

    # Hex's own files and a `_build` the tarball does not carry are left out
    # of the snapshot, so the tree cannot speak for them. Nor for `priv`,
    # which a package may fill at runtime on the user's machine.
    for rel <- [
          "hex_metadata.config",
          ".hex",
          "_build/prod/lib/pkg/ebin/x.beam",
          "priv/cldr/locales/en.json",
          "priv",
          "Priv/x.json",
          "PRIV"
        ] do
      event = in_mix_exs(ev("file_read", "file:read_file/1", %{"path" => rel}), pkg, 5)
      assert {:refuse, "compile-time host read" <> _} = Events.decide(event, ctx, "pkg"), rel
    end

    # The same reads outside mix.exs (a macro or module body at compile
    # time) keep today's refusal: only mix.exs evaluation was meant.
    for event <- [wildcard, read, absolute] do
      at_compile = Map.put(event, "user", @user)
      assert {:refuse, "compile-time host read: " <> _} = Events.decide(at_compile, ctx, "pkg")
    end

    # A case variant of a tarball entry is never absent: a case-insensitive
    # file system would find the entry.
    for rel <- ["readme.md", "MIX.EXS", "README.MD"] do
      event = in_mix_exs(ev("file_read", "file:read_file/1", %{"path" => rel}), pkg, 5)
      assert {:refuse, "compile-time host read" <> _} = Events.decide(event, ctx, "pkg"), rel
    end

    # A path the tarball holds but the Hex file list leaves out stays refused.
    {:ok, members} = matched_tree(pkg)["pkg"]
    File.mkdir_p!(Path.join(pkg, "priv"))
    File.write!(Path.join(pkg, "priv/x"), "x")
    sha = :sha256 |> :crypto.hash("x") |> Base.encode16(case: :lower)
    listed = build(dir, proj, report, trees: %{"pkg" => {:ok, Map.put(members, "priv/x", sha)}})

    assert {:refuse, _} =
             Events.decide(
               ev("file_read", "file:read_file/1", %{"path" => "priv/x"}),
               listed,
               "pkg"
             )

    # A tree that is not verified, or a native dependency, keeps the refusal.
    unverified = build(dir, proj, report, trees: %{"pkg" => {:unverified, "no verified tarball"}})
    native = build(dir, proj, report, trees: matched_tree(pkg), native: ["pkg"])

    for c <- [unverified, native] do
      assert {:refuse, _} = Events.decide(read, c, "pkg")
    end

    # Outside every dependency window a relative path resolves to nothing.
    assert {:refuse, _} = Events.decide(read, ctx, :outside)
  end

  test "an absent path that is there at judge time cannot be judged",
       %{dir: dir, proj: proj, pkg: pkg} do
    ctx = build(dir, proj, report(dir, proj, pkg, []), trees: matched_tree(pkg))
    File.mkdir_p!(Path.join(pkg, "guides"))
    File.write!(Path.join(pkg, "guides/a.md"), "# a")

    read = ev("file_read", "file:read_file/1", %{"path" => "guides/a.md"})
    listing = ev("file_read", "file:list_dir/1", %{"path" => "guides", "listing" => true})
    probe = ev("file_read", "file:read_file_info/1", %{"path" => "guides"})

    for event <- [read, listing, probe] do
      event = in_mix_exs(event, pkg, 5)

      assert {:unjudged, "portability could not be judged (dependency tree changed" <> _} =
               Events.decide(event, ctx, "pkg")
    end
  end

  # A missing file under any dependency's priv (or its _build priv) is where
  # runtime or Mix-task data appears on a user's machine (ex_cldr's
  # priv/cldr/locales): its absence on the builder says nothing about the
  # user's, in any window.
  test "a missing path under a priv dir refuses in every window", %{dir: dir, proj: proj} do
    pkg = Path.join([proj, "deps", "pkg"])
    File.mkdir_p!(Path.join(pkg, "priv/cldr/locales"))
    File.write!(Path.join(pkg, "priv/cldr/locales/en.json"), "{}")
    build_priv = Path.join(proj, "_build/host/lib/pkg/priv")
    File.mkdir_p!(build_priv)
    File.write!(Path.join(build_priv, "kept"), "")

    ctx = build(dir, proj, report(dir, proj, pkg, []), hex_files: ~w(lib README.md mix.exs priv))

    missing = [
      Path.join(pkg, "priv/cldr/locales/xx.json"),
      Path.join(pkg, "priv/cldr/nowhere"),
      Path.join(pkg, "Priv/x"),
      Path.join(build_priv, "xx.json"),
      Path.join(build_priv, "deep/x")
    ]

    for path <- missing,
        mfa <- ["file:read_file/1", "file:read_file_info/1", "prim_file:read_file_info/2"],
        owner <- ["pkg", :outside, "other"] do
      event = ev("file_read", mfa, %{"path" => path})

      assert {:refuse, "compile-time host read: " <> _} = Events.decide(event, ctx, owner),
             "#{path} #{mfa} #{inspect(owner)}"
    end

    listing =
      ev("file_read", "file:list_dir/1", %{
        "path" => Path.join(pkg, "priv/none"),
        "listing" => true
      })

    assert {:refuse, _} = Events.decide(listing, ctx, "pkg")

    # Also in the dependency's mix.exs.
    in_mix =
      in_mix_exs(ev("file_read", "file:read_file/1", %{"path" => "priv/cldr/xx.json"}), pkg, 5)

    assert {:refuse, "compile-time host read" <> _} = Events.decide(in_mix, ctx, "pkg")

    # Paths that exist keep today's rules.
    for path <- [
          Path.join(pkg, "priv/cldr/locales/en.json"),
          Path.join(pkg, "priv/cldr/locales"),
          Path.join(build_priv, "kept")
        ] do
      assert :ignore =
               Events.decide(ev("file_read", "file:read_file/1", %{"path" => path}), ctx, "pkg"),
             path
    end

    # A missing listed path outside priv is unchanged.
    assert :ignore =
             Events.decide(
               ev("file_read", "file:read_file/1", %{"path" => Path.join(pkg, "lib/none.ex")}),
               ctx,
               "pkg"
             )
  end

  describe "a dependency's own compile reading its own source priv (judge revision 23)" do
    # pkg is natively built, ships `priv/templates/a.txt`, and its build
    # `priv` is Mix's link to `deps/pkg/priv`; `user` is a closure
    # dependency that depends on it. rustler's `Mix.Tasks.Rustler.New`
    # reading its templates through `:code.priv_dir(:rustler)`.
    defp linked_ctx(dir, proj, pkg, opts \\ []) do
      File.mkdir_p!(Path.join(pkg, "priv/templates"))
      File.write!(Path.join(pkg, "priv/templates/a.txt"), "a")
      build_priv = Path.join(proj, "_build/host/lib/pkg/priv")
      File.ln_s!("../../../../deps/pkg/priv", build_priv)
      user = Path.join([proj, "deps", "user"])
      File.mkdir_p!(Path.join(user, "lib"))
      File.mkdir_p!(Path.join(proj, "_build/host/lib/user/ebin"))

      dependent = %{
        "app" => "user",
        "dest" => user,
        "build" => Path.join(proj, "_build/host/lib/user"),
        "manager" => "mix",
        "children" => ["pkg"]
      }

      report = report(dir, proj, pkg, [])
      report = update_in(report.closure["deps"], &(&1 ++ [dependent]))
      ctx = build(dir, proj, report, Keyword.merge([native: ["pkg"]], opts))
      %{ctx: ctx, file: Path.join(build_priv, "templates/a.txt"), build_priv: build_priv}
    end

    defp read(path, mfa \\ "file:read_file/2"),
      do: ev("file_read", mfa, %{"path" => path})

    test "a content read through Mix's link is observed with the refusal it would be",
         %{dir: dir, proj: proj, pkg: pkg} do
      %{ctx: ctx, file: file} = linked_ctx(dir, proj, pkg)

      for mfa <- ~w(file:read_file/1 file:read_file/2 prim_file:read_file/1 file:open/2
                    file:consult/1 erl_prim_loader:get_file/1) do
        assert {:observe, "own_priv_reads", item} = Events.decide(read(file, mfa), ctx, "pkg")
        assert %{"app" => "pkg", "source" => "priv/templates/a.txt", "ts" => 50} = item

        assert item["refusal"] ==
                 "compile-time host read: #{mfa} #{file} in Pkg.f/0 (lib/pkg.ex:3)"
      end

      # The source path itself, relative in its own window, is the same file.
      assert {:observe, "own_priv_reads", %{"source" => "priv/templates/a.txt"}} =
               Events.decide(read("priv/templates/a.txt"), ctx, "pkg")
    end

    test "a probe, a listing or the priv dir itself keeps its refusal",
         %{dir: dir, proj: proj, pkg: pkg} do
      %{ctx: ctx, file: file, build_priv: build_priv} = linked_ctx(dir, proj, pkg)

      for event <- [
            read(file, "file:read_file_info/2"),
            read(file, "prim_file:read_file_info/2"),
            read(file, "file:read_link_info/2"),
            ev("file_read", "file:list_dir/1", %{
              "path" => Path.join(build_priv, "templates"),
              "listing" => true
            }),
            read(build_priv, "file:read_file/2")
          ] do
        assert {:refuse, "compile-time host read: " <> _} = Events.decide(event, ctx, "pkg"),
               inspect(event)
      end
    end

    test "another app's read, a read outside every window or from mix.exs keeps its refusal",
         %{dir: dir, proj: proj, pkg: pkg} do
      %{ctx: ctx, file: file} = linked_ctx(dir, proj, pkg)

      for owner <- ["user", :outside, :quiet, "other"] do
        assert {:refuse, "compile-time host read: " <> _} =
                 Events.decide(read(file), ctx, owner),
               inspect(owner)
      end

      in_mix = in_mix_exs(read(file), pkg, 5)
      refute match?({:observe, "own_priv_reads", _}, Events.decide(in_mix, ctx, "pkg"))
    end

    test "a build priv of its own keeps its refusal", %{dir: dir, proj: proj, pkg: pkg} do
      # No link: a directory in the build dir, which the compile may have
      # written (`Context.own_priv/2`, judge revision 21).
      build_priv = Path.join(proj, "_build/host/lib/pkg/priv")
      File.mkdir_p!(build_priv)
      File.write!(Path.join(build_priv, "gen.txt"), "g")
      File.mkdir_p!(Path.join(pkg, "priv"))
      File.write!(Path.join(pkg, "priv/gen.txt"), "g")
      ctx = build(dir, proj, report(dir, proj, pkg, []), native: ["pkg"])

      for path <- [Path.join(build_priv, "gen.txt"), Path.join(pkg, "priv/gen.txt")] do
        assert {:refuse, "compile-time host read: " <> _} =
                 Events.decide(read(path), ctx, "pkg"),
               path
      end
    end

    test "a link that resolves out of the source priv keeps its refusal",
         %{dir: dir, proj: proj, pkg: pkg} do
      outside = Path.join(dir, "outside")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "a.txt"), "a")

      # The source priv itself a link out of the package's tree.
      File.ln_s!(outside, Path.join(pkg, "priv"))
      build_priv = Path.join(proj, "_build/host/lib/pkg/priv")
      File.ln_s!("../../../../deps/pkg/priv", build_priv)
      ctx = build(dir, proj, report(dir, proj, pkg, []), native: ["pkg"])

      assert {:refuse, "compile-time host read: " <> _} =
               Events.decide(read(Path.join(build_priv, "a.txt")), ctx, "pkg")

      # A link inside the source priv out of the tree.
      File.rm!(Path.join(pkg, "priv"))
      File.mkdir_p!(Path.join(pkg, "priv"))
      File.ln_s!(Path.join(outside, "a.txt"), Path.join(pkg, "priv/b.txt"))
      ctx = build(dir, proj, report(dir, proj, pkg, []), native: ["pkg"])

      assert {:refuse, "compile-time host read: " <> _} =
               Events.decide(read(Path.join(build_priv, "b.txt")), ctx, "pkg")

      # The build priv a link to anywhere but the package's own source priv.
      File.rm!(build_priv)
      File.ln_s!(outside, build_priv)
      ctx = build(dir, proj, report(dir, proj, pkg, []), native: ["pkg"])

      assert {:refuse, "compile-time host read: " <> _} =
               Events.decide(read(Path.join(build_priv, "a.txt")), ctx, "pkg")
    end

    test "a missing file in its priv refuses first", %{dir: dir, proj: proj, pkg: pkg} do
      %{ctx: ctx, build_priv: build_priv} = linked_ctx(dir, proj, pkg)

      assert {:refuse, "compile-time host read: " <> _} =
               Events.decide(read(Path.join(build_priv, "templates/none.txt")), ctx, "pkg")
    end

    test "a non-native dependency's own priv read is a plain readable source read",
         %{dir: dir, proj: proj, pkg: pkg} do
      %{file: file} = linked_ctx(dir, proj, pkg)

      ctx =
        build(dir, proj, report(dir, proj, pkg, []), hex_files: ~w(lib priv README.md mix.exs))

      assert :ignore = Events.decide(read(file), ctx, "pkg")
    end
  end

  describe "a Mix alias copying a file of its own tree onto another (judge revision 27)" do
    # pkg (no native build) ships `installer/a.eex` and `priv/t/a.eex`, and
    # its build priv is Mix's link to `deps/pkg/priv`. phoenix's
    # `compile: [&copy_core_components/1, "compile"]`: a fun of its own
    # aliases that tail-calls `File.cp!/2`, run by Mix's alias runner in
    # the process `elixir -S mix` runs its tasks in.

    # The process the driver compiles pkg in, which fires its sentinel.
    @driver "<0.95.0>"

    defp tree_ctx(dir, proj, pkg, opts \\ []) do
      File.mkdir_p!(Path.join(pkg, "installer"))
      File.mkdir_p!(Path.join(pkg, "priv/t"))
      File.write!(Path.join(pkg, "installer/a.eex"), "a")
      File.write!(Path.join(pkg, "priv/t/a.eex"), "a")
      build_priv = Path.join(proj, "_build/host/lib/pkg/priv")
      File.ln_s!("../../../../deps/pkg/priv", build_priv)
      files = ~w(lib README.md mix.exs installer priv)
      opts = Keyword.put(opts, :hex_files, files)
      report = %{report(dir, proj, pkg, []) | sentinels: [%{app: "pkg", ts: 1, pid: @driver}]}
      %{ctx: build(dir, proj, report, opts), build_priv: build_priv}
    end

    @mix_main %{"module" => "Elixir.Kernel.CLI", "function" => "-exec_fun/2-fun-0-"}
    # The frame `File.cp/3` leaves right below each of its three calls.
    @cp_file %{"module" => "Elixir.File", "function" => "do_cp_file", "arity" => 4}

    defp copy(pkg, mfa \\ "file:copy/2", opts \\ []) do
      dest = Keyword.get(opts, :path, Path.join(pkg, "priv/t/a.eex"))

      arg =
        if mfa in ~w(file:copy/2 file:copy/3 prim_file:copy/3),
          do: %{
            "path" => dest,
            "from" => Keyword.get(opts, :from, Path.join(pkg, "installer/a.eex")),
            "from_kind" => "read"
          },
          else: %{"path" => dest}

      "file_write"
      |> ev(mfa, arg,
        extent: "dispatcher",
        user: nil,
        first: Keyword.get(opts, :first, {"Elixir.Mix.Task", "run_alias", 6})
      )
      |> Map.put("bottom", Keyword.get(opts, :bottom, @mix_main))
      |> Map.put("pid", Keyword.get(opts, :pid, @driver))
      |> Map.put("caller", Keyword.get(opts, :caller, @cp_file))
      |> Map.put("caller_kind", Keyword.get(opts, :caller_kind, "toolchain"))
    end

    test "is observed with the refusal it would be", %{dir: dir, proj: proj, pkg: pkg} do
      %{ctx: ctx, build_priv: build_priv} = tree_ctx(dir, proj, pkg)
      dest = Path.join(pkg, "priv/t/a.eex")

      for mfa <- ~w(file:copy/2 file:copy/3) do
        assert {:observe, "own_tree_copies", item} = Events.decide(copy(pkg, mfa), ctx, "pkg")

        assert %{"app" => "pkg", "path" => "priv/t/a.eex", "source" => "installer/a.eex"} =
                 item

        assert item["refusal"] == "compile-time write outside ebin: #{mfa} #{dest}"
      end

      # The mode File.cp/3 writes onto the copy: no source.
      assert {:observe, "own_tree_copies", %{"path" => "priv/t/a.eex", "source" => nil}} =
               Events.decide(copy(pkg, "file:write_file_info/3"), ctx, "pkg")

      # Through Mix's link from the build priv, and relative in its window.
      for path <- [Path.join(build_priv, "t/a.eex"), "priv/t/a.eex"] do
        assert {:observe, "own_tree_copies", %{"path" => "priv/t/a.eex"}} =
                 Events.decide(copy(pkg, "file:copy/2", path: path), ctx, "pkg")
      end

      # An alias fun whose own frame, in pkg's own mix.exs, stays on the stack.
      framed = %{in_mix_exs(copy(pkg), pkg, 9) | "extent" => "frame"}

      assert {:observe, "own_tree_copies", %{"source" => "installer/a.eex"}} =
               Events.decide(framed, ctx, "pkg")
    end

    test "keeps its refusal made anywhere else", %{dir: dir, proj: proj, pkg: pkg} do
      %{ctx: ctx} = tree_ctx(dir, proj, pkg)
      framed = %{in_mix_exs(copy(pkg), pkg, 9) | "extent" => "frame"}
      task = %{"module" => "Elixir.Task.Supervised", "function" => "reply"}

      for event <- [
            # Another process: one the alias spawned, or a compiler worker.
            copy(pkg, "file:copy/2", bottom: task),
            Map.delete(copy(pkg), "bottom"),
            %{framed | "bottom" => task},
            # Not Mix's alias runner: its task runner, or a module body.
            copy(pkg, "file:copy/2", first: {"Elixir.Mix.Task", "run_task", 5}),
            copy(pkg, "file:copy/2", first: {"Elixir.Mix.Task", "run_alias", 5}),
            %{copy(pkg) | "extent" => "lineage"},
            %{copy(pkg) | "extent" => "frame", "user" => @user},
            %{in_mix_exs(copy(pkg), proj, 9) | "extent" => "frame"},
            %{framed | "extent" => "dispatcher"}
          ] do
        assert {:refuse, "compile-time write outside ebin: file:copy/2 " <> _} =
                 Events.decide(event, ctx, "pkg"),
               inspect(event)
      end

      for owner <- ["other", :outside, :quiet] do
        assert {:refuse, "compile-time write outside ebin: " <> _} =
                 Events.decide(copy(pkg), ctx, owner),
               inspect(owner)
      end
    end

    test "keeps its refusal unless File.cp/3 made the call", %{dir: dir, proj: proj, pkg: pkg} do
      # The trace keeps no byte count and no open modes: `File.copy/3` or
      # `:file.copy/3` with a count cuts the file short, `{dest, [:append]}`
      # appends, and `File.write_stat/3` sets any mode. Only the toolchain's
      # `File.do_cp_file/4` copies a whole file by name and then the
      # source's mode.
      %{ctx: ctx} = tree_ctx(dir, proj, pkg)
      copy! = %{"module" => "Elixir.File", "function" => "copy!", "arity" => 3}
      alias_fun = %{"module" => "Elixir.Pkg.MixProject", "function" => "cut", "arity" => 1}

      for mfa <- ~w(file:copy/2 file:copy/3 file:write_file_info/3),
          opts <- [
            [caller: copy!],
            [caller: alias_fun, caller_kind: "user"],
            [caller_kind: "user"],
            [caller: nil, caller_kind: "none"]
          ] do
        event = copy(pkg, mfa, opts)

        assert {:refuse, "compile-time write outside ebin: " <> _} =
                 Events.decide(event, ctx, "pkg"),
               inspect({mfa, opts})
      end

      for mfa <- ~w(prim_file:copy/3 file:write_file_info/2) do
        assert {:refuse, "compile-time write outside ebin: " <> _} =
                 Events.decide(copy(pkg, mfa), ctx, "pkg"),
               mfa
      end
    end

    test "keeps its refusal in any process but the one Mix builds it in",
         %{dir: dir, proj: proj, pkg: pkg} do
      # `Kernel.CLI.run/1` is public: package code that sets
      # `System.no_halt(true)` gets a process of its own whose bottom frame
      # is the one Mix's own process has, and it can run beside the
      # compiler's workers while they read the file being copied.
      %{ctx: ctx} = tree_ctx(dir, proj, pkg)
      framed = %{in_mix_exs(copy(pkg), pkg, 9) | "extent" => "frame"}

      for event <- [copy(pkg), framed], pid <- ["<0.96.0>", nil] do
        assert {:refuse, "compile-time write outside ebin: " <> _} =
                 Events.decide(%{event | "pid" => pid}, ctx, "pkg"),
               inspect({event["extent"], pid})
      end
    end

    test "keeps its refusal outside its own window", %{dir: dir, proj: proj, pkg: pkg} do
      # A fun of pkg's own mix.exs run while another dependency's window is
      # open, or none is: Mix runs it in that dependency's source dir, or
      # wherever it is, not pkg's, which a relative path resolves against.
      %{ctx: ctx} = tree_ctx(dir, proj, pkg)
      framed = %{in_mix_exs(copy(pkg), pkg, 9) | "extent" => "frame"}

      for event <- [framed, copy(pkg)], ts <- [150, nil] do
        assert {:refuse, "compile-time write outside ebin: " <> _} =
                 Events.decide(%{event | "ts" => ts}, ctx, "pkg"),
               inspect({event["extent"], ts})
      end
    end

    test "keeps its refusal for a copy onto its own source", %{dir: dir, proj: proj, pkg: pkg} do
      # `File.cp/3` tells the two apart by `Path.expand/1` alone: through
      # Mix's link from the build priv it copies the file onto itself, and
      # opening it for writing empties it first.
      %{ctx: ctx, build_priv: build_priv} = tree_ctx(dir, proj, pkg)
      source = Path.join(pkg, "priv/t/a.eex")

      for mfa <- ~w(file:copy/2 file:copy/3),
          path <- [Path.join(build_priv, "t/a.eex"), source, "priv/t/a.eex"] do
        assert {:refuse, "compile-time write outside ebin: " <> _} =
                 Events.decide(copy(pkg, mfa, path: path, from: source), ctx, "pkg"),
               inspect({mfa, path})
      end
    end

    test "keeps its refusal out of its own tree, or for any other write",
         %{dir: dir, proj: proj, pkg: pkg} do
      %{ctx: ctx} = tree_ctx(dir, proj, pkg)
      elsewhere = Path.join(dir, "elsewhere")
      File.mkdir_p!(elsewhere)
      File.write!(Path.join(elsewhere, "a.eex"), "a")

      for event <- [
            copy(pkg, "file:copy/2", path: Path.join(elsewhere, "a.eex")),
            copy(pkg, "file:copy/2", path: pkg),
            copy(pkg, "file:copy/2", path: Path.join(pkg, "../elsewhere/a.eex")),
            copy(pkg, "file:copy/2", from: Path.join(elsewhere, "a.eex")),
            copy(pkg, "file:write_file/3"),
            copy(pkg, "file:change_mode/2"),
            copy(pkg, "file:delete/1"),
            copy(pkg, "file:make_symlink/2")
          ] do
        assert {:refuse, "compile-time write outside ebin: " <> _} =
                 Events.decide(event, ctx, "pkg"),
               inspect(event)
      end
    end

    test "keeps its refusal in a natively built dependency", %{dir: dir, proj: proj, pkg: pkg} do
      %{ctx: ctx} = tree_ctx(dir, proj, pkg, native: ["pkg"])

      for mfa <- ~w(file:copy/2 file:write_file_info/3) do
        assert {:refuse, "compile-time write outside ebin: " <> _} =
                 Events.decide(copy(pkg, mfa), ctx, "pkg")
      end
    end
  end

  describe "differential builds' varied reads" do
    # With the job's `differential` flag (`Context.differential`), a read
    # whose value a variant build changes is observed, carrying the refusal
    # it would be, for `NccWorker.Portability.Differential` to settle.
    # Without the flag nothing changes.
    defp differential(ctx), do: %{ctx | differential: true}

    defp plain_args(owner_extent) do
      ev("env", "init:get_plain_arguments/0", %{},
        extent: owner_extent,
        first: {"erl_eval", "do_apply", 7},
        user: nil
      )
    end

    test "the scheduler count anywhere is observed as a varied read", %{ctx: ctx} do
      for key <- ~w(schedulers_online schedulers) do
        event = ev("os_identity", "erlang:system_info/1", %{"key" => key})

        assert {:refuse, reason} = Events.decide(event, ctx, "pkg")
        assert reason =~ "compile-time host read: erlang:system_info/1 (#{key})"

        assert {:observe, "varied_reads", item} = Events.decide(event, differential(ctx), "pkg")
        assert item["read"] == "schedulers"
        assert item["refusal"] =~ "compile-time host read: erlang:system_info/1 (#{key})"
        assert item["mfa"] == "erlang:system_info/1"
      end

      for key <- ~w(logical_processors nif_version wordsize) do
        assert {:refuse, _} =
                 Events.decide(
                   ev("os_identity", "erlang:system_info/1", %{"key" => key}),
                   differential(ctx),
                   "pkg"
                 )
      end
    end

    test "HOME is a varied read; any other init argument is not", %{ctx: ctx} do
      home = ev("env", "init:get_argument/1", %{"name" => "home"})

      assert {:observe, "varied_reads", %{"read" => "home"}} =
               Events.decide(home, differential(ctx), "pkg")

      assert {:observe, "varied_reads", %{"read" => "home"}} =
               Events.decide(home, differential(ctx), :outside)

      for name <- ~w(root progname pa) do
        assert {:refuse, "compile-time host read: init:get_argument/1" <> _} =
                 Events.decide(
                   ev("env", "init:get_argument/1", %{"name" => name}),
                   differential(ctx),
                   "pkg"
                 )
      end

      assert {:refuse, _} =
               Events.decide(ev("env", "init:get_arguments/0", %{}), differential(ctx), "pkg")
    end

    test "the plain arguments are varied only outside every window", %{ctx: ctx} do
      assert {:refuse, "compile-time host read: init:get_plain_arguments/0" <> _} =
               Events.decide(plain_args("dispatcher"), ctx, :outside)

      assert {:observe, "varied_reads", %{"read" => "plain_args", "refusal" => refusal}} =
               Events.decide(plain_args("dispatcher"), differential(ctx), :outside)

      assert refusal =~ "init:get_plain_arguments/0"

      # A compile can test them against a literal no variant guesses.
      assert {:refuse, _} = Events.decide(plain_args("dispatcher"), differential(ctx), "pkg")

      assert {:refuse, _} =
               Events.decide(
                 ev("env", "init:get_plain_arguments/0", %{}),
                 differential(ctx),
                 "pkg"
               )
    end

    test "a read in a dependency's mix.exs stays R4's", %{ctx: ctx, pkg: pkg} do
      event =
        in_mix_exs(ev("os_identity", "erlang:system_info/1", %{"key" => "schedulers"}), pkg, 4)

      assert {:observe, "mix_exs_allowed", _} = Events.decide(event, ctx, "pkg")
      assert Events.decide(event, differential(ctx), "pkg") == Events.decide(event, ctx, "pkg")

      File.write!(Path.join(pkg, "mix.exs"), String.duplicate("#", 300 * 1024))

      assert {:refuse, "compile-time host read in mix.exs: " <> _} =
               Events.decide(event, differential(ctx), "pkg")
    end

    test "the empty path names no file on any host", %{ctx: ctx} do
      for mfa <- ~w(file:read_file_info/1 file:read_file_info/2 file:read_link_info/2
                    prim_file:read_file_info/1) do
        event = ev("file_read", mfa, %{"path" => ""})
        assert {:refuse, "compile-time host read: " <> _} = Events.decide(event, ctx, "pkg")
        assert :ignore = Events.decide(event, differential(ctx), "pkg")
      end

      # Its bytes are no stat: only the stat-type reads.
      assert {:refuse, _} =
               Events.decide(
                 ev("file_read", "file:read_file/1", %{"path" => ""}),
                 differential(ctx),
                 "pkg"
               )
    end
  end
end
