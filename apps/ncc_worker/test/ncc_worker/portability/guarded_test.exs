defmodule NccWorker.Portability.GuardedTest do
  # Coverage drop 2026-11-22, F4: a closure dependency's reviewed probe that
  # only decides whether it defines its guarded modules taints no
  # dependent whose compile never touched them.
  use ExUnit.Case, async: true

  alias NccWorker.Portability.{Context, Guarded}

  @moduletag :tmp_dir

  @guard "Elixir.WebSockAdapter.CowboyAdapter"
  @reason "compile-time probe of a dependency outside the closure: cowboy_websocket via " <>
            "Code.ensure_loaded?/1"

  # pkg depends on websock_adapter (0.7.2 locked); `beams` are
  # `%{app => [source]}`, compiled for real into each app's ebin.
  defp ctx(dir, beams, version \\ "0.7.2") do
    deps =
      Map.new(["pkg", "websock_adapter"], fn app ->
        build = Path.join([dir, "_build", "host", "lib", app])
        File.mkdir_p!(Path.join(build, "ebin"))

        {app,
         %{build: build, dest: nil, manager: "mix", children: [], native?: false, hex_files: nil}}
      end)

    deps = put_in(deps["pkg"].children, ["websock_adapter"])

    modules =
      for {app, sources} <- beams, source <- sources, into: %{} do
        [{module, binary}] = compile(source)

        File.write!(
          Path.join([dir, "_build", "host", "lib", app, "ebin", "#{module}.beam"]),
          binary
        )

        {Atom.to_string(module), app}
      end

    releases = %{"websock_adapter" => %{name: "websock_adapter", version: version, checksum: "x"}}
    %Context{package: "pkg", deps: deps, modules: modules, hex: {nil, releases}}
  end

  # With debug info, as Mix compiles a dependency (the test VM's own
  # compiler option leaves it out).
  defp compile(source) do
    source = String.replace(source, ~r/ do\n/, " do\n  @compile :debug_info\n", global: false)

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      send(self(), {:compiled, Code.compile_string(source)})
    end)

    receive do
      {:compiled, [{module, _binary}] = compiled} ->
        :code.purge(module)
        :code.delete(module)
        compiled
    end
  end

  defp unique, do: System.unique_integer([:positive])

  # websock_adapter's main module, as 0.7.2 has it: the guarded module only
  # as an atom in a tuple.
  defp adapter(n) do
    """
    defmodule WebSockAdapter.Fx#{n} do
      def tuple_for(websock, state), do: {WebSockAdapter.CowboyAdapter, {websock, state}, %{}}
    end
    """
  end

  defp site_event do
    %{
      "channel" => "probe",
      "mfa" => "code:ensure_loaded/1",
      "caller" => %{"module" => "Elixir.Code", "function" => "ensure_loaded?", "arity" => 1},
      "user" => %{
        "module" => "elixir_compiler_128",
        "function" => "__FILE__",
        "line" => 1,
        "file" => "lib/websock_adapter/cowboy_adapter.ex"
      },
      "arg" => %{"module" => "cowboy_websocket", "by_package" => true}
    }
  end

  defp tags(ctx),
    do: [{"websock_adapter", @reason, Guarded.site(site_event(), ctx, "websock_adapter")}]

  test "the reviewed site, by its file, form, probed module and release", %{tmp_dir: dir} do
    c = ctx(dir, %{})
    assert Guarded.site(site_event(), c, "websock_adapter") == "websock_adapter:cowboy_adapter"

    for {event, owner, ctx} <- [
          {site_event(), "pkg", c},
          {put_in(site_event(), ["user", "file"], "lib/websock_adapter.ex"), "websock_adapter",
           c},
          {put_in(site_event(), ["user", "function"], "__MODULE__"), "websock_adapter", c},
          {put_in(site_event(), ["arg", "module"], "cowboy_req"), "websock_adapter", c},
          {put_in(site_event(), ["arg", "by_package"], false), "websock_adapter", c},
          {%{site_event() | "mfa" => "erlang:function_exported/3"}, "websock_adapter", c},
          {site_event(), "websock_adapter", ctx(Path.join(dir, "old"), %{}, "0.4.5")},
          {site_event(), "websock_adapter", ctx(Path.join(dir, "new"), %{}, "0.7.3")}
        ] do
      assert Guarded.site(event, ctx, owner) == nil, inspect({event["user"], owner})
    end
  end

  test "a dependent that only names the guarded module's package is waived", %{tmp_dir: dir} do
    n = unique()

    c =
      ctx(dir, %{
        "websock_adapter" => [adapter(n)],
        "pkg" => [
          "defmodule Pkg.Fx#{n} do\n  def up(a, b), do: WebSockAdapter.Fx#{n}.tuple_for(a, b)\nend\n"
        ]
      })

    assert %{
             "websock_adapter" => %{reasons: reasons, entries: ["websock_adapter:cowboy_adapter"]}
           } =
             Guarded.waivers(c, %{events: [], children: %{}}, tags(c))

    assert MapSet.to_list(reasons) == [@reason]
  end

  # The guarded module's own build is never waived: the package is the
  # prober.
  test "the prober's own build is not waived", %{tmp_dir: dir} do
    c = %{ctx(dir, %{"websock_adapter" => [adapter(unique())]}) | package: "websock_adapter"}
    assert Guarded.waivers(c, %{events: [], children: %{}}, tags(c)) == %{}
  end

  # A dependent whose beams call, capture or apply the guarded module reads
  # its signatures: it stays tainted.
  for {name, body} <- [
        {"call", "def f(r, s), do: WebSockAdapter.CowboyAdapter.init(r, s)"},
        {"capture", "def f, do: &WebSockAdapter.CowboyAdapter.init/2"},
        {"apply", "def f(r, s), do: apply(WebSockAdapter.CowboyAdapter, :init, [r, s])"},
        # Optimised out of the beam, but the checker read it.
        {"dead code",
         "def f, do: if(false, do: WebSockAdapter.CowboyAdapter.init(1, 2), else: :ok)"}
      ] do
    @body body
    test "a dependent whose beam refers to the guarded module by #{name} stays tainted",
         %{tmp_dir: dir} do
      n = unique()

      source = """
      defmodule Pkg.Fx#{n} do
        @compile {:no_warn_undefined, WebSockAdapter.CowboyAdapter}
        #{@body}
      end
      """

      c = ctx(dir, %{"websock_adapter" => [adapter(n)], "pkg" => [source]})
      assert Guarded.waivers(c, %{events: [], children: %{}}, tags(c)) == %{}
    end
  end

  # A dependent's compile-time call, probe or behaviour lookup of the
  # guarded module is a traced probe of it; an application probe of the
  # prober reads its `.app`'s module list.
  for {name, event} <- [
        {"compile-time call",
         %{
           "channel" => "probe",
           "mfa" => "code:ensure_loaded/1",
           "arg" => %{"module" => "Elixir.WebSockAdapter.CowboyAdapter", "by_package" => true}
         }},
        {"loaded-now probe",
         %{
           "channel" => "probe",
           "mfa" => "erlang:function_exported/3",
           "arg" => %{"module" => "Elixir.WebSockAdapter.CowboyAdapter", "by_package" => true}
         }},
        {"behaviour lookup",
         %{
           "channel" => "probe",
           "mfa" => "code:ensure_loaded/1",
           "arg" => %{"module" => "Elixir.WebSockAdapter.CowboyAdapter", "attribute" => true}
         }},
        {"application probe",
         %{
           "channel" => "app_probe",
           "mfa" => "application_controller:get_key/2",
           "arg" => %{"app" => "websock_adapter"}
         }}
      ] do
    @event event
    test "a #{name} of the guarded module in any window keeps the taint", %{tmp_dir: dir} do
      c = ctx(dir, %{"websock_adapter" => [adapter(unique())]})
      assert Guarded.waivers(c, %{events: [@event], children: %{}}, tags(c)) == %{}

      child = %{events: [@event]}
      assert Guarded.waivers(c, %{events: [], children: %{"x" => child}}, tags(c)) == %{}
    end
  end

  # The prober's ebin holds the guarded beam in the other world, and its
  # `.app` lists it: a compile-time read or listing of that ebin, from any
  # window, sees what the builder did not. A read of its `include` (an
  # Erlang header, joken's of jose's) is the same either way.
  test "a read or listing of the prober's ebin keeps the taint", %{tmp_dir: dir} do
    c = ctx(dir, %{"websock_adapter" => [adapter(unique())]})
    ebin = Path.join([dir, "_build", "host", "lib", "websock_adapter", "ebin"])
    read = &%{"channel" => "file_read", "mfa" => "file:list_dir/1", "arg" => %{"path" => &1}}

    for path <- [ebin, Path.join(ebin, "websock_adapter.app")] do
      assert Guarded.waivers(c, %{events: [read.(path)], children: %{}}, tags(c)) == %{}

      child = %{events: [read.(path)]}
      assert Guarded.waivers(c, %{events: [], children: %{"x" => child}}, tags(c)) == %{}
    end

    # A wildcard whose literal dir reaches the ebin; a relative path; a
    # copy out of the ebin.
    lib = Path.join([dir, "_build", "host", "lib"])

    for event <- [
          read.(Path.join(lib, "*/ebin/*.beam")),
          read.("ebin/websock_adapter.app"),
          %{
            "channel" => "file_write",
            "mfa" => "file:copy/2",
            "arg" => %{"from" => Path.join(ebin, "websock_adapter.app"), "path" => "/tmp/x"}
          }
        ] do
      assert Guarded.waivers(c, %{events: [event], children: %{}}, tags(c)) == %{}, inspect(event)
    end

    # The cwd, a wildcard elsewhere: no concern.
    cwd = %{"channel" => "file_read", "mfa" => "file:get_cwd/0", "arg" => %{"cwd" => true}}
    other = read.(Path.join([dir, "deps", "pkg", "priv", "*.json"]))

    assert %{"websock_adapter" => _} =
             Guarded.waivers(c, %{events: [cwd, other], children: %{}}, tags(c))

    header =
      read.(Path.join([dir, "_build", "host", "lib", "websock_adapter", "include", "x.hrl"]))

    assert %{"websock_adapter" => _} =
             Guarded.waivers(c, %{events: [header], children: %{}}, tags(c))
  end

  test "a build that holds the guarded module, or a refusal not of the site, keeps the taint",
       %{tmp_dir: dir} do
    n = unique()

    built =
      ctx(dir, %{
        "websock_adapter" => [adapter(n), "defmodule WebSockAdapter.CowboyAdapter do\nend\n"]
      })

    assert Guarded.waivers(built, %{events: [], children: %{}}, tags(built)) == %{}

    c = ctx(Path.join(dir, "b"), %{"websock_adapter" => [adapter(n)]})
    other = [{"websock_adapter", @reason, nil} | tags(c)]
    assert Guarded.waivers(c, %{events: [], children: %{}}, other) == %{}
  end

  test "a beam without readable Elixir debug info refers to the guarded module",
       %{tmp_dir: dir} do
    n = unique()
    [{module, binary}] = compile(adapter(n))
    {:ok, ^module, chunks} = :beam_lib.all_chunks(binary)
    stripped = Enum.reject(chunks, fn {id, _} -> id == ~c"Dbgi" end)
    {:ok, without} = :beam_lib.build_module(stripped)
    path = Path.join(dir, "stripped.beam")
    File.write!(path, without)
    assert Guarded.refers?(path, [@guard])

    plain = Path.join(dir, "plain.beam")
    File.write!(plain, binary)
    refute Guarded.refers?(plain, [@guard])
    refute Guarded.refers?(plain, [{:prefix, "Elixir.JOSE.Poison"}])
    assert Guarded.refers?(Path.join(dir, "missing.beam"), [@guard])

    # Compiled without debug info (`{:debug_info_v1, :elixir_erl, :none}`).
    {:ok, ^module, chunks} = :beam_lib.all_chunks(binary)
    none = :erlang.term_to_binary({:debug_info_v1, :elixir_erl, :none})

    chunks =
      Enum.map(chunks, fn
        {~c"Dbgi", _} -> {~c"Dbgi", none}
        c -> c
      end)

    {:ok, no_info} = :beam_lib.build_module(chunks)
    path = Path.join(dir, "no_info.beam")
    File.write!(path, no_info)
    assert Guarded.refers?(path, [@guard])
  end
end
