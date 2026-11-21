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

  test "a declared dependency whose tarball is not cached holds no known module", %{tmp_dir: dir} do
    index = Declared.index(ctx(dir, cached: false))
    assert index.modules == %{}
    # Its application is known all the same: the declaration names it.
    assert index.apps["fx_opt"] == ["pkg"]
  end

  test "a declaration from another repository is not read", %{tmp_dir: dir} do
    other = List.keyreplace(req("fx_opt"), "repository", 0, {"repository", "acme"})
    index = Declared.index(ctx(dir, requirements: [other]))
    assert index == %{modules: %{}, apps: %{}}
  end

  test "an unreadable declarer's tarball declares nothing", %{tmp_dir: dir} do
    c = ctx(dir)
    c = %{c | hex: {elem(c.hex, 0), %{}}}
    assert Declared.index(c) == %{modules: %{}, apps: %{}}
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
      :ok
    end

    releases = %{"pkg" => pkg, "telemetry" => tel}
    assert Declared.fetch(home, releases, [], fetch: fetch) == {:ok, ["jason"]}
    assert_received {:fetch, ["jason"], ^home}

    # Nothing missing: no fetch.
    TracerFixtures.hex_release(home, "jason", ["lib"])
    assert Declared.fetch(home, releases, [], fetch: fetch) == {:ok, []}
    refute_received {:fetch, _, _}
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
end
