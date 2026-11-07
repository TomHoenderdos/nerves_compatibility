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
      "first" => %{"module" => Keyword.get(opts, :first, "Elixir.Pkg")},
      "user" => Keyword.get(opts, :user, @user)
    }
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

  test "OS identity: path handling and the OTP release pass, a direct read refuses", %{ctx: ctx} do
    assert :ignore =
             Events.decide(ev("os_identity", "os:type/0", %{}, first: "Elixir.Path"), ctx, "pkg")

    assert :ignore =
             Events.decide(ev("os_identity", "os:type/0", %{}, first: "filename"), ctx, "pkg")

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
                 first: "filename"
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
    for bottom <- [
          nil,
          %{"module" => "Elixir.Pkg", "function" => "f", "arity" => 0},
          %{"module" => "epp"}
        ] do
      assert {:refuse, _} =
               Events.decide(
                 epp("erlang:system_info/1", %{"key" => "machine"}, bottom),
                 ctx,
                 "pkg"
               )
    end

    assert {:refuse, _} =
             Events.decide(
               Map.delete(epp("erlang:system_info/1", %{"key" => "machine"}), "bottom"),
               ctx,
               "pkg"
             )

    # A user frame on the stack is not the epp server's own work.
    framed = %{
      epp("erlang:system_info/1", %{"key" => "machine"})
      | "extent" => "frame",
        "user" => @user
    }

    assert {:refuse, _} = Events.decide(framed, ctx, "pkg")

    # Every other read in that process stays user.
    assert {:refuse, _} =
             Events.decide(epp("erlang:system_info/1", %{"key" => "wordsize"}), ctx, "pkg")

    getenv = %{epp("os:getenv/1", %{"name" => "X"}) | "channel" => "env"}

    assert {:refuse, "compile-time host read: os:getenv/1" <> _} =
             Events.decide(getenv, ctx, "pkg")

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

    for key <- ["version", "system_architecture", "os_type", "machine"] do
      assert {:refuse, _} = Events.decide(wordsize(key, @big_int), ctx, "pkg"), key
    end

    other = %{wordsize("wordsize", @big_int) | "mfa" => "os:type/0", "arg" => %{}}
    assert {:refuse, _} = Events.decide(other, ctx, "pkg")
  end

  test "a stack without a user frame names its extent", %{ctx: ctx} do
    assert {:refuse,
            "compile-time host read: os:getenv/1 (truncated stack, first frame Elixir.Macro)"} =
             Events.decide(
               ev("env", "os:getenv/1", %{"name" => "X"},
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
               ev("os_identity", "os:type/0", %{}, first: "Elixir.Path", extent: "unjudged"),
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
    deps_read = in_mix_exs(ev("env", "os:getenv/1", %{"name" => "XV"}), pkg, 4)
    opts_read = put_in(deps_read, ["user", "line"], 5)

    assert {:observe, "mix_exs_allowed", %{"mfa" => "os:getenv/1", "line" => 4}} =
             Events.decide(deps_read, ctx, "pkg")

    assert {:refuse, "compile-time host read in mix.exs: os:getenv/1 sets elixirc_options" <> _} =
             Events.decide(opts_read, ctx, "pkg")

    # A precomputed slice is used instead of reading the file again.
    slices = Events.mix_exs_slices(ctx, [{"pkg", deps_read}])
    assert [{_path, {:ok, _}}] = Map.to_list(slices)

    assert {:observe, "mix_exs_allowed", _} = Events.decide(deps_read, ctx, "pkg", slices)

    # A frame without a line cannot be sliced.
    no_line = put_in(deps_read, ["user", "line"], nil)

    assert {:refuse, "compile-time host read: os:getenv/1" <> _} =
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

  test "a mix.exs the slice cannot read refuses", %{ctx: ctx, pkg: pkg} do
    File.write!(Path.join(pkg, "mix.exs"), String.duplicate("#", 300 * 1024))
    event = in_mix_exs(ev("env", "os:getenv/1", %{"name" => "XV"}), pkg, 4)

    assert {:refuse, "compile-time host read in mix.exs: os:getenv/1 " <> _} =
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
end
