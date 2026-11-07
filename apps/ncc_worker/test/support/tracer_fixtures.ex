defmodule NccWorker.TracerFixtures do
  @moduledoc """
  Path-dependency projects for the compile-time tracer tests: a wrapper
  project whose top-level dependencies live under `deps/<app>` (so the layout
  is a real project's), each with its own `mix.exs` or `rebar.config` and a
  `hex_metadata.config` listing its files as a Hex tarball would.
  """

  alias NccWorker.Tracer
  alias NccWorker.Tracer.Report

  @spec project(String.t(), [String.t()], %{String.t() => map()}) :: String.t()
  def project(root, top, deps) do
    proj = Path.join(root, "proj")
    File.mkdir_p!(Path.join(proj, "deps"))
    File.write!(Path.join(proj, "mix.exs"), wrapper_mix_exs(top, deps))
    Enum.each(deps, fn {name, spec} -> write_dep(proj, name, spec, deps) end)
    proj
  end

  @spec env(String.t()) :: [{String.t(), String.t()}]
  def env(proj) do
    [
      {"MIX_ENV", "prod"},
      {"MIX_BUILD_PATH", Path.join([proj, "_build", "host"])},
      {"MIX_DEPS_PATH", Path.join(proj, "deps")}
    ]
  end

  @spec trace(String.t(), [String.t()], keyword()) :: map()
  def trace(proj, packages, opts \\ []) do
    root = Path.dirname(proj)
    trace_dir = Path.join(root, "trace")
    log = Path.join(root, "trace.log")
    File.write!(log, "")

    result =
      Tracer.run(
        proj,
        packages,
        [
          trace_dir: trace_dir,
          env: env(proj),
          native: Keyword.get(opts, :native, []),
          log_file: log,
          timeout_ms: Keyword.get(opts, :timeout_ms, 240_000),
          extra_env: Keyword.get(opts, :extra_env, [])
        ] ++ Keyword.take(opts, [:reap, :cleanup_find])
      )

    %{result: result, report: Report.read(trace_dir), log: File.read!(log)}
  end

  @doc """
  The portability verdict of a `trace/3` result for `package`. `opts` go to
  `NccWorker.Portability.judge/5` (`releases:`, `hex_home:`, see
  `hex_release/3`).
  """
  @spec judge(String.t(), String.t(), map(), [String.t()], keyword()) ::
          NccWorker.Portability.verdict()
  def judge(proj, package, traced, native \\ [], opts \\ []),
    do: NccWorker.Portability.judge(proj, package, traced.report, native, opts)

  @doc """
  A Hex release of path dependency `app` (version 0.1.0) whose tarball, in
  the Hex cache `home`, lists `files`: the verified file list a real Hex
  dependency's source reads are judged against. Returns the lock entry for
  `releases:`. The tarball holds `VERSION`, `metadata.config` and, when
  `contents` (`%{path => body}`) is given, a `contents.tar.gz` of them: the
  judge reads a rebar3 dependency's `rebar.config` from there.
  """
  @spec hex_release(String.t(), String.t(), [String.t()], %{String.t() => binary()}) ::
          {String.t(), map()}
  def hex_release(home, app, files, contents \\ %{}) do
    dir = Path.join(home, "packages/hexpm")
    File.mkdir_p!(dir)
    tar = Path.join(dir, "#{app}-0.1.0.tar")

    meta =
      Enum.map_join([{"name", app}, {"version", "0.1.0"}, {"files", files}], "", fn term ->
        :io_lib.format(~c"~p.~n", [term]) |> IO.chardata_to_string()
      end)

    entries = [{~c"VERSION", "3"}, {~c"metadata.config", meta}] ++ contents_entry(contents)
    :ok = :erl_tar.create(String.to_charlist(tar), entries)
    sum = :sha256 |> :crypto.hash(File.read!(tar)) |> Base.encode16(case: :lower)
    {app, %{name: app, version: "0.1.0", checksum: sum}}
  end

  defp contents_entry(contents) when map_size(contents) == 0, do: []

  defp contents_entry(contents) do
    gz = Path.join(System.tmp_dir!(), "ncc-contents-#{System.unique_integer([:positive])}.tar.gz")
    files = for {path, body} <- contents, do: {String.to_charlist(path), body}
    :ok = :erl_tar.create(String.to_charlist(gz), files, [:compressed])
    bytes = File.read!(gz)
    File.rm!(gz)
    [{~c"contents.tar.gz", bytes}]
  end

  @doc "A dependency with one `lib/<name>.ex` holding `body`, plus `extra` spec keys."
  @spec lib(String.t(), String.t(), map()) :: map()
  def lib(name, body, extra \\ %{}), do: Map.merge(%{files: %{"lib/#{name}.ex" => body}}, extra)

  @doc "A module whose attribute `@x` evaluates `expr` at compile time."
  @spec attr_module(String.t(), String.t()) :: String.t()
  def attr_module(module, expr),
    do: "defmodule #{module} do\n  @x #{expr}\n  def x, do: @x\nend\n"

  @doc "A dependency `mix.exs` whose `project/0` ends with `extra` (Elixir source, starting with a comma)."
  @spec mix_exs(String.t(), String.t()) :: String.t()
  def mix_exs(name, extra) do
    """
    defmodule #{Macro.camelize(name)}.MixProject do
      use Mix.Project
      def project, do: [app: :#{name}, version: "0.1.0", deps: deps()#{extra}]
      defp deps, do: []
    end
    """
  end

  @doc "A one-function Erlang module."
  @spec erl_module(String.t()) :: String.t()
  def erl_module(name), do: "-module(#{name}).\n-export([f/0]).\nf() -> ok.\n"

  defp wrapper_mix_exs(top, deps) do
    entries = Enum.map_join(top, ", ", &dep_entry(&1, "deps/" <> &1, deps))

    """
    defmodule FixtureWrapper.MixProject do
      use Mix.Project
      def project, do: [app: :fixture_wrapper, version: "0.1.0", deps: [#{entries}]]
    end
    """
  end

  # `hex_name:` gives the dependency the Hex package name a Hex dependency
  # carries in its `:hex` option, for a package whose name is not its app's.
  defp dep_entry(name, path, deps) do
    spec = Map.get(deps, name, %{})
    hex = if h = spec[:hex_name], do: ", hex: :#{h}", else: ""

    case spec[:manager] do
      :rebar3 -> "{:#{name}, path: #{inspect(path)}, manager: :rebar3#{hex}}"
      _ -> "{:#{name}, path: #{inspect(path)}#{hex}}"
    end
  end

  defp write_dep(proj, name, spec, deps) do
    dir = Path.join([proj, "deps", name])
    File.mkdir_p!(dir)
    files = Map.merge(manifest_files(name, spec, deps), Map.get(spec, :files, %{}))
    links = Map.get(spec, :links, %{})
    Enum.each(files, fn {rel, body} -> write!(Path.join(dir, rel), body) end)
    Enum.each(links, fn {rel, target} -> link!(Path.join(dir, rel), target) end)
    write_hex_metadata(dir, name, listed(spec, Map.keys(files) ++ Map.keys(links)))
  end

  defp manifest_files(name, %{manager: :rebar3} = spec, _deps) do
    %{
      "rebar.config" => Map.get(spec, :rebar_config, "{erl_opts, []}.\n"),
      "src/#{name}.app.src" =>
        ~s({application, #{name}, [{vsn, "0.1.0"}, {description, "fixture"}, ) <>
          ~s({applications, [kernel, stdlib]}]}.\n)
    }
  end

  defp manifest_files(name, spec, deps) do
    %{"mix.exs" => Map.get(spec, :mix_exs) || dep_mix_exs(name, Map.get(spec, :deps, []), deps)}
  end

  defp dep_mix_exs(name, children, deps) do
    entries = Enum.map_join(children, ", ", &dep_entry(&1, "../" <> &1, deps))

    """
    defmodule #{Macro.camelize(name)}.MixProject do
      use Mix.Project
      def project, do: [app: :#{name}, version: "0.1.0", deps: [#{entries}]]
      def application, do: [extra_applications: [:logger]]
    end
    """
  end

  defp listed(spec, paths) do
    case Map.get(spec, :hex, :all) do
      :all -> Enum.sort(paths)
      other -> other
    end
  end

  defp write_hex_metadata(_dir, _name, :none), do: :ok

  defp write_hex_metadata(dir, name, files) do
    body =
      Enum.map_join([{"name", name}, {"version", "0.1.0"}, {"files", files}], "", fn term ->
        :io_lib.format(~c"~p.~n", [term]) |> IO.chardata_to_string()
      end)

    File.write!(Path.join(dir, "hex_metadata.config"), body)
  end

  defp write!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  defp link!(path, target) do
    File.mkdir_p!(Path.dirname(path))
    File.ln_s!(target, path)
  end
end
