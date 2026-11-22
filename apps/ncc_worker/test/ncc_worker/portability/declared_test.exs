defmodule NccWorker.Portability.DeclaredTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability.{Context, Declared}
  alias NccWorker.TracerFixtures

  @moduletag :tmp_dir

  defp req(name, optional \\ true),
    do: [
      {"name", name},
      {"app", name},
      {"optional", optional},
      {"requirement", "~> 0.1"},
      {"repository", "hexpm"}
    ]

  # pkg declares fx_opt (optional, absent from the build) and fx_dep
  # (present); fx_opt's tarball, any version, is in the run's Hex cache.
  defp ctx(dir, opts \\ []) do
    home = Path.join(dir, "hex")

    {_, pkg} =
      TracerFixtures.hex_release(home, "pkg", ["lib"], %{}, [
        {"requirements", Keyword.get(opts, :requirements, [req("fx_opt"), req("fx_dep", false)])}
      ])

    {_, dep} = TracerFixtures.hex_release(home, "fx_dep", ["lib"])

    if Keyword.get(opts, :cached, true) do
      TracerFixtures.hex_release(home, "fx_opt", ["lib", "src"], %{
        "lib/fx_opt.ex" => """
        defmodule FxOpt do
          defmodule Inner do
          end

          defimpl String.Chars do
            def to_string(_), do: "x"
          end
        end

        defprotocol FxOpt.Proto do
          def f(x)
        end

        defimpl FxOpt.Proto, for: [Integer, Atom] do
          def f(x), do: x
        end

        defmodule __MODULE__.Ignored do
        end
        """,
        "src/fx_opt_erl.erl" => "-module(fx_opt_erl).\n-export([f/0]).\nf() -> ok.\n"
      })
    end

    deps =
      Map.new(["pkg", "fx_dep"], fn app ->
        {app,
         %{build: nil, dest: nil, manager: "mix", children: [], native?: false, hex_files: nil}}
      end)

    deps = put_in(deps["pkg"].children, ["fx_dep"])
    %Context{package: "pkg", deps: deps, hex: {home, %{"pkg" => pkg, "fx_dep" => dep}}}
  end

  test "an absent declared dependency's modules and app, by the declarer", %{tmp_dir: dir} do
    index = Declared.index(ctx(dir))

    for m <- ~w(Elixir.FxOpt Elixir.FxOpt.Inner Elixir.String.Chars.FxOpt Elixir.FxOpt.Proto
                Elixir.FxOpt.Proto.Integer Elixir.FxOpt.Proto.Atom fx_opt_erl),
        do: assert(index.modules[m] == ["pkg"], m)

    assert index.apps["fx_opt"] == ["pkg"]
    # Present dependencies are the closure's, not declared-absent.
    refute Map.has_key?(index.apps, "fx_dep")
  end

  # Round 3, R2-3: only an optional declaration counts (a non-optional one
  # the build lacks is a `targets:` dependency, which Mix still makes a
  # child of its declarer), and only when the lock, not only the closure,
  # lacks the dependency.
  test "a non-optional declared dependency is not declared-absent", %{tmp_dir: dir} do
    index = Declared.index(ctx(dir, requirements: [req("fx_opt", false)]))
    assert index == %{modules: %{}, apps: %{}, owners: %{}, packages: %{}}
  end

  test "a declared dependency the lock holds is not declared-absent", %{tmp_dir: dir} do
    c = ctx(dir)
    {home, releases} = c.hex
    {_, opt} = TracerFixtures.hex_release(home, "fx_opt", ["lib"])
    index = Declared.index(%{c | hex: {home, Map.put(releases, "fx_opt", opt)}})
    assert index == %{modules: %{}, apps: %{}, owners: %{}, packages: %{}}
  end

  test "each module names the declared packages that define it", %{tmp_dir: dir} do
    index = Declared.index(ctx(dir))
    assert index.owners["Elixir.FxOpt.Inner"] == ["fx_opt"]
    assert index.owners["fx_opt_erl"] == ["fx_opt"]
    assert index.packages == %{"fx_opt" => "fx_opt"}
  end

  test "a declared dependency whose tarball is not cached holds no known module", %{tmp_dir: dir} do
    index = Declared.index(ctx(dir, cached: false))
    assert index.modules == %{}
    # Its application is known all the same: the declaration names it.
    assert index.apps["fx_opt"] == ["pkg"]
  end

  test "a declaration from another repository is not read", %{tmp_dir: dir} do
    other = List.keyreplace(req("fx_opt"), "repository", 0, {"repository", "acme"})
    index = Declared.index(ctx(dir, requirements: [other]))
    assert index == %{modules: %{}, apps: %{}, owners: %{}, packages: %{}}
  end

  test "an unreadable declarer's tarball declares nothing", %{tmp_dir: dir} do
    c = ctx(dir)
    c = %{c | hex: {elem(c.hex, 0), %{}}}
    assert Declared.index(c) == %{modules: %{}, apps: %{}, owners: %{}, packages: %{}}
  end
end

defmodule NccWorker.Portability.DeclaredFetchTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability.Declared
  alias NccWorker.TracerFixtures

  @moduletag :tmp_dir

  defp req(name),
    do: [
      {"name", name},
      {"app", name},
      {"optional", true},
      {"requirement", "~> 1.0"},
      {"repository", "hexpm"}
    ]

  # The locked releases declare jason (absent, not cached), decimal (absent,
  # cached) and telemetry (locked): only jason is fetched.
  test "fetches the absent declared dependencies the Hex cache lacks", %{tmp_dir: dir} do
    home = Path.join(dir, "hex")

    {_, pkg} =
      TracerFixtures.hex_release(home, "pkg", ["lib"], %{}, [
        {"requirements", [req("jason"), req("decimal"), req("telemetry")]}
      ])

    {_, tel} = TracerFixtures.hex_release(home, "telemetry", ["lib"])
    TracerFixtures.hex_release(home, "decimal", ["lib"])
    me = self()

    fetch = fn names, opts ->
      send(me, {:fetch, names, opts[:home]})
      {:ok, %{fetched: ["jason-1.4.5"], failed: []}}
    end

    releases = %{"pkg" => pkg, "telemetry" => tel}

    assert Declared.fetch(home, releases, [], fetch: fetch) ==
             {:ok, %{fetched: ["jason-1.4.5"], failed: []}}

    assert_received {:fetch, ["jason"], ^home}

    # No probe the index decides was traced (round 3, R2-5): no fetch.
    assert Declared.fetch(home, releases, [], fetch: fetch, relevant: false) ==
             {:ok, %{fetched: [], failed: []}}

    refute_received {:fetch, _, _}

    # Nothing missing: no fetch.
    TracerFixtures.hex_release(home, "jason", ["lib"])
    assert Declared.fetch(home, releases, [], fetch: fetch) == {:ok, %{fetched: [], failed: []}}
    refute_received {:fetch, _, _}
  end

  # Round 3, R2-5: only a package the script reported fetched, with the
  # tarball it named, goes into the run's Hex cache. A checksum error, a
  # crash or a kill mid-way leaves that package unknown, which refuses.
  test "only the packages the fetch reported go into the cache", %{tmp_dir: dir} do
    home = Path.join(dir, "hex")
    out = Path.join(dir, "out")
    File.mkdir_p!(Path.join(home, "packages/hexpm"))

    for {n, v} <- [{"jason", "1.4.5"}, {"decimal", "2.0.0"}, {"poison", "6.0.0"}] do
      File.mkdir_p!(Path.join(out, n))
      File.write!(Path.join([out, n, "#{n}-#{v}.tar"]), "tar")
    end

    output = """
    Downloading...
    NCC_FETCH ok jason jason-1.4.5.tar
    NCC_FETCH error decimal Mix.Error
    NCC_FETCH ok poison ../jason/jason-1.4.5.tar
    NCC_FETCH ok other other-1.0.0.tar
    """

    assert Declared.collect(output, ["jason", "decimal", "poison"], out, home) ==
             %{fetched: ["jason-1.4.5"], failed: ["decimal", "poison"]}

    assert File.ls!(Path.join(home, "packages/hexpm")) == ["jason-1.4.5.tar"]
  end

  test "the bounded run kills a command past its deadline", %{tmp_dir: dir} do
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout, _output} =
             Declared.run_bounded(System.find_executable("sleep"), ["30"], [], dir, 300)

    assert System.monotonic_time(:millisecond) - started < 5_000

    assert {:ok, "hi\n"} =
             Declared.run_bounded(System.find_executable("echo"), ["hi"], [], dir, 5_000)
  end

  test "a failed fetch is no error: those modules stay unknown", %{tmp_dir: dir} do
    home = Path.join(dir, "hex")

    {_, pkg} =
      TracerFixtures.hex_release(home, "pkg", ["lib"], %{}, [{"requirements", [req("jason")]}])

    assert Declared.fetch(home, %{"pkg" => pkg}, [], fetch: fn _, _ -> {:error, :timeout} end) ==
             {:error, :timeout}
  end

  test "the fetch script names only validated package names" do
    script = Declared.fetch_script(["jason", "sweet_xml"], "/out")
    assert script =~ ~s(["jason", "sweet_xml"])
    assert script =~ ~s("/out")
  end

  # Coverage drop 2026-11-22, F7: Hex's update check, which the first
  # `hex.package` task of the VM starts, can crash `Hex.Registry.Server`
  # after that task closed the registry (`:ets.insert(nil, {:last_update,
  # ...})`); a fetch in flight then exits with `:noproc`. The script tries a
  # failed name once more, so one crash costs no package.
  test "the fetch script tries a failed name once more, then reports it", %{tmp_dir: dir} do
    run = fn answers, out ->
      {:ok, agent} = Agent.start_link(fn -> answers end)

      stub = fn "hex.package", ["fetch", n, "--output", to] ->
        case Agent.get_and_update(agent, fn [a | rest] -> {a, rest} end) do
          :ok ->
            File.mkdir_p!(to)
            File.write!(Path.join(to, "#{n}-1.4.5.tar"), "tar")

          {:exit, why} ->
            exit(why)
        end
      end

      script =
        ["jason"]
        |> Declared.fetch_script(out)
        |> String.replace("Mix.Task.rerun(", "stub.(")
        |> String.replace("Process.sleep(", "nap.(")

      ExUnit.CaptureIO.capture_io(fn ->
        Code.eval_string(script, stub: stub, nap: fn _ -> :ok end)
      end)
    end

    assert run.([{:exit, :noproc}, :ok], Path.join(dir, "a")) ==
             "NCC_FETCH ok jason jason-1.4.5.tar\n"

    assert run.([{:exit, :noproc}, {:exit, :noproc}], Path.join(dir, "b")) ==
             "NCC_FETCH error jason exit\n"

    assert run.([:ok], Path.join(dir, "c")) == "NCC_FETCH ok jason jason-1.4.5.tar\n"
  end
end
