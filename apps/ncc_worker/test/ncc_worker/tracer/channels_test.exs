defmodule NccWorker.Tracer.ChannelsTest do
  use ExUnit.Case, async: true

  defp classify(m, f, args), do: :ncc_tracer_channels.classify(m, f, args)

  test "the pattern list covers every R1 channel" do
    patterns = :ncc_tracer_channels.patterns()

    for mfa <- [
          {:os, :type, 0},
          {:erlang, :system_info, 1},
          {:os, :getenv, 1},
          {:init, :get_plain_arguments, 0},
          {:erlang, :open_port, 2},
          {:os, :find_executable, 1},
          {:file, :read_file, 1},
          {:prim_file, :read_file, 1},
          {:erl_prim_loader, :get_file, 1},
          {:file, :write_file, 3},
          {:file, :change_time, 2},
          {:prim_file, :make_dir, 1},
          {:inet, :gethostname, 0},
          {:socket, :open, 2},
          {:code, :lib_dir, 1},
          {:application, :loaded_applications, 0},
          {:crypto, :info_lib, 0},
          {:erlang, :load_nif, 2},
          {:erl_ddll, :load_driver, 2},
          {System, :version, 0},
          {Version, :match?, 2},
          {:erlang, :system_flag, 2},
          {:trace, :_, :_},
          {:dbg, :_, :_},
          {:application, :get_env, 2},
          {:application, :get_all_env, 1},
          {:prim_file, :copy, 3}
        ] do
      assert mfa in patterns, inspect(mfa)
    end
  end

  test "OS identity, environment and programs" do
    assert {:os_identity, %{}} = classify(:os, :type, [])
    assert {:os_identity, %{key: "otp_release"}} = classify(:erlang, :system_info, [:otp_release])
    assert {:env, %{name: "HOME"}} = classify(:os, :getenv, [~c"HOME"])
    assert {:programs, %{cmd: "uname"}} = classify(:os, :cmd, [~c"uname"])
    assert {:programs, %{port: port}} = classify(:erlang, :open_port, [{:spawn, ~c"ls"}, []])
    assert port =~ "spawn"
  end

  test "reads, the working directory and wildcards" do
    assert {:file_read, %{path: "/etc/hosts"}} = classify(:file, :read_file, ["/etc/hosts"])
    assert {:file_read, %{path: "x.hrl"}} = classify(:prim_file, :read_file_info, [~c"x.hrl", []])
    assert {:file_read, %{cwd: true}} = classify(:file, :get_cwd, [])
    assert {:file_read, %{path: "lib"}} = classify(:filelib, :wildcard, ["lib/*.ex"])
    assert {:file_read, %{path: "/d/priv"}} = classify(:filelib, :wildcard, [~c"priv/*", ~c"/d"])
    assert {:file_read, %{path: "a"}} = classify(:file, :open, ["a", [:read, :binary]])
  end

  test "writes, including open modes, renames, copies and links" do
    assert {:file_write, %{path: "a"}} = classify(:file, :open, ["a", [:append, :binary]])
    assert {:file_write, %{path: "a"}} = classify(:file, :open, ["a", :write])
    assert {:file_write, %{path: "o"}} = classify(:file, :write_file, ["o", "x", []])

    assert {:file_write, %{path: "new", from: "old", from_kind: :write}} =
             classify(:file, :rename, ["old", "new"])

    assert {:file_write, %{path: "to", from: "from", from_kind: :read}} =
             classify(:file, :copy, [{"from", [:read]}, "to"])

    assert {:file_write, %{path: "to", from: "from", from_kind: :read}} =
             classify(:prim_file, :copy, ["from", "to", :infinity])

    assert {:file_write, %{path: "link"}} = classify(:file, :make_symlink, ["target", "link"])

    assert {:file_write, %{path: "t"}} =
             classify(:file, :change_time, ["t", {{2026, 1, 1}, {0, 0, 0}}])
  end

  test "install locations, crypto, native loading, Elixir version, integrity and config" do
    assert {:install, %{what: :lib_dir, app: :kernel}} = classify(:code, :lib_dir, [:kernel])
    assert {:install, %{what: :root_dir}} = classify(:code, :root_dir, [])
    assert {:crypto, %{}} = classify(:crypto, :info_lib, [])
    assert {:native, %{path: "priv/x"}} = classify(:erlang, :load_nif, [~c"priv/x", 0])
    assert {:elixir_version, %{}} = classify(System, :version, [])

    assert {:elixir_version, %{left: ~s("1.19.3"), right: ~s(">= 1.19.0")}} =
             classify(Version, :match?, ["1.19.3", ">= 1.19.0"])

    assert {:integrity, %{flag: "backtrace_depth"}} =
             classify(:erlang, :system_flag, [:backtrace_depth, 1])

    assert {:integrity, %{}} = classify(:dbg, :stop, [])

    assert {:config, %{app: "logger", key: "level"}} =
             classify(:application, :get_env, [:logger, :level])

    assert {:config, %{all: true}} = classify(:application, :get_all_env, [:logger])
  end

  test "anything else is unknown, and odd arguments do not crash" do
    assert :unknown = classify(:lists, :reverse, [[1]])
    assert {:file_read, %{path: _}} = classify(:file, :read_file, [{:not, :a, :path}])
  end

  test "the session's own BIFs, the tracer, the probe and unsticking are integrity" do
    patterns = :ncc_tracer_channels.patterns()

    for mfa <- [
          {:erts_internal, :trace, 4},
          {:erts_internal, :trace_pattern, 4},
          {:erts_internal, :trace_session_destroy, 1},
          {:erts_internal, :trace_info, 3},
          {:ncc_tracer, :_, :_},
          {:ncc_tracer_probe, :fire, 1},
          {:code, :unstick_mod, 1},
          {:code, :unstick_dir, 1}
        ] do
      assert mfa in patterns, inspect(mfa)
    end

    assert {:integrity, %{}} = classify(:erts_internal, :trace_session_destroy, [{:x, 0}])

    assert {:integrity, %{}} =
             classify(:erts_internal, :trace_pattern, [{:x, 0}, {:os, :type, 0}, false, []])

    assert {:integrity, %{}} = classify(:ncc_tracer, :finish, ["ok"])
    assert {:integrity, %{}} = classify(:ncc_tracer_probe, :fire, [~c"__final__"])
    assert {:integrity, %{}} = classify(:code, :unstick_mod, [:os])

    assert {:erlang, :process_info, 2} in patterns
    assert {:integrity, %{}} = classify(:erlang, :process_info, [self()])
    assert {:integrity, %{}} = classify(:erlang, :process_info, [self(), :dictionary])
    assert {:integrity, %{}} = classify(:erlang, :process_info, [self(), {:dictionary, :k}])
    assert {:integrity, %{}} = classify(:erlang, :process_info, [self(), [:status, :backtrace]])
    assert {:integrity, %{}} = classify(:erlang, :process_info, [self(), :messages])
    assert :unknown = classify(:erlang, :process_info, [self(), [:status, :memory]])
  end
end
