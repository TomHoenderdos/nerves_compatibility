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
          {:prim_file, :copy, 3},
          {:file, :set_cwd, 1},
          {:prim_file, :set_cwd, 1}
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
    assert {:file_read, %{path: "lib", listing: true}} = classify(:file, :list_dir, ["lib"])

    assert {:file_read, %{path: "lib", listing: true}} =
             classify(:prim_file, :list_dir_all, ["lib"])

    refute Map.has_key?(elem(classify(:file, :read_file, ["a"]), 1), :listing)
  end

  # Item 5b: Path.wildcard/2 passes Path.Wildcard as filelib:wildcard/2's
  # second argument, a module, not a directory.
  test "a wildcard's module argument is not a directory; wildcard/3 is traced" do
    assert {:file_read, %{path: "lib/assets", listing: true}} =
             classify(:filelib, :wildcard, ["lib/assets/**", Path.Wildcard])

    assert {:file_read, %{path: "lib/assets", listing: true}} =
             classify(:filelib, :wildcard, ["lib/assets/*", :file])

    assert {:file_read, %{path: "/d/priv", listing: true}} =
             classify(:filelib, :wildcard, [~c"priv/*", ~c"/d", :file])

    # Any other module's reads are untraced: a read with no path, which the
    # judge refuses.
    for args <- [["x/*", :my_mod], ["x/*", ~c"/d", :my_mod]] do
      assert {:file_read, %{module: "my_mod"} = arg} = classify(:filelib, :wildcard, args)
      refute Map.has_key?(arg, :path)
    end

    assert {:filelib, :wildcard, 3} in :ncc_tracer_channels.patterns()
  end

  test "System.user_home, File.lstat and File.read_link reach a channel (R4 allowlist)" do
    patterns = :ncc_tracer_channels.patterns()

    for mfa <- [
          {:init, :get_argument, 1},
          {:file, :read_link_info, 1},
          {:file, :read_link_info, 2},
          {:file, :read_link, 1},
          {:file, :read_link_all, 1},
          {:prim_file, :read_link_info, 1},
          {:prim_file, :read_link_info, 2},
          {:prim_file, :read_link, 1},
          {:prim_file, :read_link_all, 1},
          {:prim_file, :list_dir_all, 1},
          {:prim_file, :get_cwd, 1}
        ] do
      assert mfa in patterns, inspect(mfa)
    end

    assert {:env, %{name: "home"}} = classify(:init, :get_argument, [:home])
    assert {:file_read, %{path: "/l"}} = classify(:file, :read_link_info, ["/l", [time: :posix]])
    assert {:file_read, %{path: "/l"}} = classify(:file, :read_link, ["/l"])
    assert {:file_read, %{path: "/l"}} = classify(:file, :read_link_all, ["/l"])
    assert {:file_read, %{path: "/l"}} = classify(:prim_file, :read_link_info, [~c"/l"])
    assert {:file_read, %{path: "/l"}} = classify(:prim_file, :read_link_all, [~c"/l"])
    assert {:file_read, %{path: "/d"}} = classify(:prim_file, :list_dir_all, [~c"/d"])
    assert {:file_read, %{cwd: true}} = classify(:prim_file, :get_cwd, [~c"c:"])
  end

  test "changing the working directory is its own channel" do
    assert {:cwd, %{path: "/x"}} = classify(:file, :set_cwd, ["/x"])
    assert {:cwd, %{path: "rel"}} = classify(:prim_file, :set_cwd, [~c"rel"])
    assert {:cwd, %{path: _}} = classify(:file, :set_cwd, [{:not, :a, :path}])
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

  test "probes of whether a module is or can be loaded, never in the patterns" do
    probes = :ncc_tracer_channels.probe_mfas()
    patterns = :ncc_tracer_channels.patterns()
    assert length(probes) == 7
    for mfa <- probes, do: refute(mfa in patterns, inspect(mfa))

    for {m, f, args} <- [
          {:code, :ensure_loaded, [:dbg]},
          {:code, :is_loaded, [:dbg]},
          {:code, :which, [:dbg]},
          {:code, :module_status, [:dbg]},
          {:code, :get_object_code, [:dbg]},
          {:erlang, :module_loaded, [:dbg]},
          {:erlang, :function_exported, [:dbg, :p, 2]}
        ] do
      assert {:probe, %{module: "dbg"}} == classify(m, f, args)
    end

    assert {:probe, %{module: ~s(<<"x">>)}} == classify(:code, :which, ["x"])
    # The install channel's code reads keep their own channel.
    assert {:install, %{what: :lib_dir}} = classify(:code, :lib_dir, [:kernel])
    assert {:install, %{what: :priv_dir}} = classify(:code, :priv_dir, [:kernel])
    assert {:install, %{what: :get_path}} = classify(:code, :get_path, [])
  end

  test "listing the loaded modules is its own channel, always patterned" do
    patterns = :ncc_tracer_channels.patterns()

    for {m, f} <- [
          code: :all_loaded,
          erlang: :loaded,
          code: :module_status,
          code: :modified_modules
        ] do
      assert {m, f, 0} in patterns
      assert {:loaded_modules, %{}} == classify(m, f, [])
    end
  end

  test "nested compiles and diagnostics captures are their own channel" do
    patterns = :ncc_tracer_channels.patterns()

    for {m, f, args} <- [
          {Code, :compile_string, ["x", "nofile"]},
          {Code, :compile_quoted, [:ok]},
          {Code, :compile_file, ["x.ex"]},
          {Code, :require_file, ["x.ex", "."]},
          {Code, :eval_string, ["1", [], []]},
          {Code, :eval_quoted, [:ok]},
          {Code, :eval_file, ["x.exs"]},
          {Code, :with_diagnostics, [[], :f]},
          {Kernel.ParallelCompiler, :compile, [[]]},
          {Module, :create, [X, :ok, []]},
          {Code, :eval_quoted_with_env, [:ok, [], %{}]},
          {Code, :eval_quoted_with_env, [:ok, [], %{}, []]},
          {Code, :load_file, ["x.exs"]},
          {Code, :load_file, ["x.exs", "."]},
          {:elixir_compiler, :string, ["1", "nofile", :f]},
          {:elixir_compiler, :quoted, [:ok, "nofile", :f]},
          {:elixir_compiler, :file, ["x.ex", :f]}
        ] do
      assert {:nested_compile, %{}} == classify(m, f, args)
      assert {m, f, length(args)} in patterns or {m, :_, :_} in patterns
    end

    # Into the type checker, any function: the tracer patterns every export.
    assert {:nested_compile, %{}} ==
             classify(Module.ParallelChecker, :fetch_export, [1, 2, 3, 4, 5])

    assert {:nested_compile, %{}} == classify(Module.ParallelChecker, :verify, [:f])
    assert {:nested_compile, %{}} == classify(Module.Types.Descr, :union, [1, 2])
    assert {:nested_compile, %{}} == classify(Module.Types, :warnings, [1, 2, 3, 4, 5, 6])
    assert {:nested_compile, %{}} == classify(:elixir_compiler, :string, [1, 2, 3])
    assert :unknown == classify(:elixir_compiler, :get_opt, [:x])
    assert :unknown == classify(Code, :ensure_loaded?, [:x])
    assert :unknown == classify(Module, :concat, [A, B])
  end

  # Mix's compile entry points return the compile's diagnostics to their
  # caller: running a compile task, and registering a hook that receives
  # them (Mix.Task.Compiler.after_compiler/2, which only prepends it to the
  # project stack). Patterned only where Mix has loaded them already.
  test "Mix's compile entry points are nested compiles" do
    mix = :ncc_tracer_channels.mix_patterns()

    for {m, f, args} <- [
          {Mix.Task, :run, ["compile.elixir"]},
          {Mix.Task, :run, ["compile", ["--force"]]},
          {Mix.Task, :rerun, ["compile.all"]},
          {Mix.Task, :rerun, [:"compile.elixir", []]},
          {Mix.Task, :run, ["deps.compile", []]},
          {Mix.Task, :run, ["fx.compile_it", []]},
          {Mix.ProjectStack, :prepend_after_compiler, [:elixir, :f]}
        ] do
      assert {:nested_compile, %{}} == classify(m, f, args), inspect({m, f, args})
      assert {m, f, length(args)} in mix
    end

    for args <- [["deps.loadpaths"], ["loadpaths", []], [:help, []], [~c"x", []], [1]],
        do: assert(:unknown == classify(Mix.Task, :run, args), inspect(args))

    assert :unknown == classify(Mix.ProjectStack, :peek, [])

    assert Enum.sort(Enum.uniq(for {m, _, _} <- mix, do: m)) ==
             [Mix, Mix.Project, Mix.ProjectStack, Mix.State, Mix.Task, :ets]

    assert :ncc_tracer_channels.mix_entry(Mix.Task)
    assert :ncc_tracer_channels.mix_entry(Mix.ProjectStack)
    assert :ncc_tracer_channels.mix_entry(Mix.Project)
    refute :ncc_tracer_channels.mix_entry(Mix.Dep)
  end

  # Item 2's gap: Mix state read through a module name no grep sees.
  test "Mix.target and Mix.Project's path functions are mix_state; config/0 is not traced" do
    mix = :ncc_tracer_channels.mix_patterns()

    for {f, a} <- [target: 0, target: 1],
        do: assert({Mix, f, a} in mix)

    for f <- [:build_path, :app_path, :compile_path],
        a <- [0, 1],
        do: assert({Mix.Project, f, a} in mix)

    refute {Mix.Project, :config, 0} in mix
    assert {:mix_state, %{fun: "target"}} = classify(Mix, :target, [])
    assert {:mix_state, %{fun: "build_path"}} = classify(Mix.Project, :build_path, [[]])
    assert :unknown = classify(Mix.Project, :config, [])
  end

  test "Mix.State and its table are mix_state only for the target key" do
    mix = :ncc_tracer_channels.mix_patterns()

    for mfa <- [
          {Mix.State, :get, 1},
          {Mix.State, :get, 2},
          {Mix.State, :fetch, 1},
          {:ets, :lookup, 2},
          {:ets, :lookup_element, 3},
          {:ets, :lookup_element, 4}
        ],
        do: assert(mfa in mix, inspect(mfa))

    for {m, f, args} <- [
          {Mix.State, :get, [:target]},
          {Mix.State, :get, [:target, :host]},
          {Mix.State, :fetch, [:target]},
          {:ets, :lookup, [Mix.State, :target]},
          {:ets, :lookup_element, [Mix.State, :target, 2]},
          {:ets, :lookup_element, [Mix.State, :target, 2, :host]}
        ],
        do: assert({:mix_state, %{fun: "target"}} == classify(m, f, args), inspect({m, f}))

    for {m, f, args} <- [
          {Mix.State, :get, [:env, :prod]},
          {:ets, :lookup, [Mix.State, :env]},
          {:ets, :lookup, [:other, :target]}
        ],
        do: assert(:unknown == classify(m, f, args), inspect({m, f, args}))

    for {m, f, a} <- [{Mix.State, :get, 2}, {:ets, :lookup, 2}, {Mix, :target, 0}],
        do: assert(:ncc_tracer_channels.mix_state(m, f, a), inspect({m, f, a}))

    # By table id too: the head matches any table's target key, guarded.
    assert [{[Mix.State, :target], []}, {[:"$1", :target], [{:is_reference, :"$1"}]}] =
             :ncc_tracer_channels.mix_state_heads({:ets, :lookup, 2})

    refute :ncc_tracer_channels.mix_state(Mix.Task, :run, 1)
    refute :ncc_tracer_channels.mix_state(:ets, :insert, 2)
  end

  test "patterned/3 says whether a call has a channel's pattern" do
    assert :ncc_tracer_channels.patterned(:ssl, :connect, 3)
    assert :ncc_tracer_channels.patterned(:dbg, :tracer, 0)
    refute :ncc_tracer_channels.patterned(:ssl, :versions, 0)
    refute :ncc_tracer_channels.patterned(:httpc, :set_options, 1)
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

  test "config reads carry the exact atom names a compile_env item needs" do
    assert {:config,
            %{
              app: "phoenix_live_view",
              key: "root_tag_attribute",
              app_name: "phoenix_live_view",
              key_name: "root_tag_attribute",
              atoms: true
            }} = classify(:application, :get_env, [:phoenix_live_view, :root_tag_attribute, nil])

    # term_bin/1 quotes such atoms; the name is the atom's own text.
    assert {:config, %{key: "'Elixir.Foo'", key_name: "Elixir.Foo", atoms: true}} =
             classify(:application, :get_env, [:fx, Foo])

    # Erlang's `null` is the atom :null here; the report's JSON decode makes it nil.
    assert {:config, %{app_name: :null, atoms: false}} =
             classify(:application, :get_env, ["fx", :k])

    assert {:config, %{app: :null, key_name: "k", atoms: false}} =
             classify(:application, :get_env, [:k])

    assert {:config, %{all: true, app_name: "phoenix"}} =
             classify(:application, :get_all_env, [:phoenix])

    # No arguments to name, and a non-atom app: null, not a crash.
    assert {:config, %{all: true, app: :null, app_name: :null}} =
             classify(:application, :get_all_env, [])

    assert {:config, %{app_name: :null}} = classify(:application, :get_all_env, ["fx"])
  end

  describe "the value a read returned" do
    defp rec(term),
      do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

    test "os:getenv/1 records :error or {:ok, binary}" do
      assert :ncc_tracer_channels.returned_value(:os, :getenv, [~c"X"], {:value, false}) ==
               rec(:error)

      assert :ncc_tracer_channels.returned_value(:os, :getenv, [~c"X"], {:value, ~c"on"}) ==
               rec({:ok, "on"})
    end

    test "application:get_env/2 records the fetch_env shape" do
      assert :ncc_tracer_channels.returned_value(
               :application,
               :get_env,
               [:a, :k],
               {:value, :undefined}
             ) ==
               rec(:error)

      assert :ncc_tracer_channels.returned_value(
               :application,
               :get_env,
               [:a, :k],
               {:value, {:ok, 42}}
             ) ==
               rec({:ok, 42})
    end

    test "application:get_env/3 cannot tell its default from a set value" do
      assert :ncc_tracer_channels.returned_value(:application, :get_env, [:a, :k, 7], {:value, 7}) ==
               "default"

      assert :ncc_tracer_channels.returned_value(:application, :get_env, [:a, :k, 7], {:value, 8}) ==
               rec({:ok, 8})
    end

    test "a huge or non-unicode value is unrecordable, an exception records nothing" do
      big = String.to_charlist(String.duplicate("x", 70_000))

      assert :ncc_tracer_channels.returned_value(:os, :getenv, [~c"X"], {:value, big}) ==
               "unrecordable"

      assert :ncc_tracer_channels.returned_value(:os, :getenv, [~c"X"], {:value, [0xD800]}) ==
               "unrecordable"

      assert :ncc_tracer_channels.returned_value(:os, :getenv, [~c"X"], :exception) == :null
      assert :ncc_tracer_channels.recorded(String.duplicate("y", 70_000)) == "unrecordable"
    end

    test "only the three reads are return-traced" do
      assert :ncc_tracer_channels.returned_mfas() ==
               [{:os, :getenv, 1}, {:application, :get_env, 2}, {:application, :get_env, 3}]

      assert :ncc_tracer_channels.returned_mfa(:os, :getenv, 1)
      refute :ncc_tracer_channels.returned_mfa(:os, :getenv, 2)
    end
  end

  describe "the write channel" do
    # The classifier hands the tracer the value's ETF, which it stores once
    # (a value line) and names by value_id: never base64 it encodes here.
    defp etf(term), do: :erlang.term_to_binary(term, [:deterministic])

    test "env writes name the variable and the value set" do
      assert {:env_write, %{name: "X", value_etf: value} = arg} =
               :ncc_tracer_channels.classify(:os, :putenv, [~c"X", ~c"1"])

      assert value == etf({:ok, "1"})
      refute Map.has_key?(arg, :value)

      assert {:env_write, %{name: "X", value_etf: unset}} =
               :ncc_tracer_channels.classify(:os, :unsetenv, [~c"X"])

      assert unset == etf(:error)
    end

    test "a value that cannot be recorded is marked, with no ETF" do
      big = String.to_charlist(String.duplicate("x", 70_000))

      assert {:env_write, %{value: "unrecordable"} = arg} =
               :ncc_tracer_channels.classify(:os, :putenv, [~c"X", big])

      refute Map.has_key?(arg, :value_etf)

      assert {:env_write, %{value: "unrecordable"}} =
               :ncc_tracer_channels.classify(:os, :putenv, [~c"X", [0xD800]])

      assert {:config_write, %{value: "unrecordable"}} =
               :ncc_tracer_channels.classify(:application, :set_env, [
                 :a,
                 :k,
                 String.duplicate("y", 70_000)
               ])
    end

    test "config writes name the app and key and the value set" do
      assert {:config_write, %{app_name: "a", key_name: "k", value_etf: v}} =
               :ncc_tracer_channels.classify(:application, :set_env, [:a, :k, 1, []])

      assert v == etf({:ok, 1})

      assert {:config_write, %{value_etf: e}} =
               :ncc_tracer_channels.classify(:application, :unset_env, [:a, :k])

      assert e == etf(:error)

      assert {:config_write, %{all: true}} =
               :ncc_tracer_channels.classify(:application, :set_env, [[{:a, [k: 1]}]])
    end

    test "the writes are patterned" do
      for mfa <- [
            {:os, :putenv, 2},
            {:os, :unsetenv, 1},
            {:application, :set_env, 3},
            {:application, :set_env, 4},
            {:application, :unset_env, 2},
            {:application, :unset_env, 3},
            {:application, :set_env, 1},
            {:application, :set_env, 2}
          ] do
        assert mfa in :ncc_tracer_channels.patterns(), inspect(mfa)
      end
    end
  end
end
