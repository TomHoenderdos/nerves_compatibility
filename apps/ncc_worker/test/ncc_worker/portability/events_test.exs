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
  defp build(dir, proj, report) do
    home = Path.join(dir, "hex-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "packages/hexpm"))
    meta = ~s({<<"files">>,[<<"lib">>,<<"README.md">>,<<"mix.exs">>]}.\n)
    tar = Path.join(dir, "pkg-#{System.unique_integer([:positive])}.tar")

    :ok =
      :erl_tar.create(String.to_charlist(tar), [{~c"VERSION", "3"}, {~c"metadata.config", meta}])

    bytes = File.read!(tar)
    File.write!(Path.join(home, "packages/hexpm/pkg-1.0.0.tar"), bytes)
    sum = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

    Context.build(proj, "pkg", report, [],
      hex_home: home,
      releases: %{"pkg" => %{name: "pkg", version: "1.0.0", checksum: sum}}
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
  test "an OS-family read under any other frame of a path module refuses", %{ctx: ctx} do
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

    for {mfa, _m, _f, arg} <- @os_reads, frame <- others do
      assert {:refuse, "compile-time host read: " <> _} =
               Events.decide(ev("os_identity", mfa, arg, first: frame), ctx, "pkg"),
             inspect({mfa, frame})
    end
  end

  defp atom_keys(arg), do: Map.new(arg, fn {k, v} -> {String.to_atom(k), v} end)

  test "OS identity: path handling and the OTP release pass, a direct read refuses", %{ctx: ctx} do
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

    assert {:refuse, "compile-time host read: os:type/0 in Pkg.f/0 (lib/pkg.ex:3)"} =
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
    # item 5d, so `os:type/0` stands for the predefined-macro reads here.)
    for bottom <- [
          nil,
          %{"module" => "Elixir.Pkg", "function" => "f", "arity" => 0},
          %{"module" => "epp"}
        ] do
      assert {:refuse, _} = Events.decide(epp("os:type/0", %{}, bottom), ctx, "pkg")
    end

    assert {:refuse, _} =
             Events.decide(Map.delete(epp("os:type/0", %{}), "bottom"), ctx, "pkg")

    # A user frame on the stack is not the epp server's own work.
    framed = %{
      epp("os:type/0", %{})
      | "extent" => "frame",
        "user" => @user
    }

    assert {:refuse, _} = Events.decide(framed, ctx, "pkg")

    # Every other read in that process stays user.
    assert {:refuse, _} =
             Events.decide(epp("erlang:system_info/1", %{"key" => "wordsize"}), ctx, "pkg")

    getenv = %{epp("os:getenv/1", %{"name" => "X"}) | "channel" => "env"}
    assert {:observe, "env_reads", %{"name" => "X"}} = Events.decide(getenv, ctx, "pkg")

    version = epp("os:version/0", %{})
    assert {:refuse, _} = Events.decide(version, ctx, "pkg")
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

    for key <- ["version", "system_architecture", "os_type", "endian"] do
      assert {:refuse, _} = Events.decide(wordsize(key, @big_int), ctx, "pkg"), key
    end

    other = %{wordsize("wordsize", @big_int) | "mfa" => "os:type/0", "arg" => %{}}
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

  test "calls into a native dependency refuse in the package's window and outside every window",
       %{ctx: ctx} do
    event = ev("native_closure", "nat:open/1", %{"module" => "nat"})

    assert {:refuse, "calls natively built dependency at compile time: nat:open/1"} =
             Events.decide(event, ctx, "pkg")

    assert {:refuse, _} = Events.decide(event, ctx, :outside)
    assert {:observe, "native_calls", _} = Events.decide(event, ctx, "other")
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
            ev("os_identity", "erlang:system_info/1", %{"key" => "endian", "code_loading" => true}),
            ev("os_identity", "os:type/0", %{"code_loading" => true}),
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
            {{"erl_prim_loader", "pathtype", 1}, "endian"}
          ] do
        event = ev("os_identity", "erlang:system_info/1", %{"key" => key}, first: first)
        assert {:refuse, _} = Events.decide(event, ctx, "pkg"), inspect(first)
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
            ~w(version nif_version driver_version endian wordsize system_architecture) ++
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
end
