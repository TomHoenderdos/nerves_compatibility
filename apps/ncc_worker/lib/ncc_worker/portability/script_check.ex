defmodule NccWorker.Portability.ScriptCheck do
  @moduledoc """
  The script check of a differential build (`NccWorker.Portability.Differential`):
  whether a rebar3 dependency's `rebar.config.script` gives the same config
  whatever plain arguments its VM was started with.

  Mix evaluates the script in its own VM when it loads the dependencies
  (`Mix.Rebar.load_config/1`), so the script sees that VM's plain
  arguments: `[mix, task | args]` for a user. A script tests them against
  literals of its own (gproc's `lists:member("doc", Args)`), which no list
  of command words can guess. So each script is evaluated as Mix evaluates
  it, in fresh VMs, on a copy of its dependency's verified tarball tree:
  with no extra arguments, with the traced compile's own (`-pa x -S mix
  ncc.trace_compile`), with the command words of a Mix user's line and
  every string literal of the dependency's `rebar.config.script` and
  `*.script` files at once, and with each literal alone (at most
  `@max_literals`). Every evaluation's config must be the first's, entry by
  entry (by key, hashed in the evaluating VM), but for `deps`: a rebar3
  dependency's `deps` never reaches its own compile (`rebar3 bare compile`
  fetches and builds nothing; Mix hands it the code path of the tree the
  user's lock resolved), and gproc's `"doc"` adds a git `edown` there alone.

  The script is package code: it runs in its own VM under `timeout(1)`, in
  a scratch copy this module removes, and nothing it prints is trusted
  beyond the key and hash lines it is asked for, read under a cap. Its
  side effects outside the copy are what the variant builds' sweeps and the
  first build's digest check are for. Never raises.
  """

  alias NccWorker.Portability.Rebar

  @max_literals 24
  @max_literal_bytes 64
  @max_files 10_000
  @max_script_bytes 1024 * 1024
  @max_out_bytes 1024 * 1024
  @timeout_sec 60
  @trace_args ~w(-pa x -S mix ncc.trace_compile)
  # Mix task words a Mix user's command line holds that rebar3 scripts test
  # their arguments against, as rebar3 command names.
  @words ~w(compile test deps.compile deps.get release docs run xref dialyzer eunit ct
            escript.build phx.server prod --force)
  # A whole Erlang string literal, escapes included, so one with an escape
  # is skipped as one rather than read from its middle.
  @literal ~r/"((?:[^"\\\n]|\\.)*)"/
  @plain ~r/\A[\x20-\x21\x23-\x5b\x5d-\x7e]{1,64}\z/

  @eval """
  config = Mix.Rebar.load_config(File.cwd!())

  grouped =
    config
    |> Enum.reject(&match?({:deps, _}, &1))
    |> Enum.group_by(fn
      entry when is_tuple(entry) and tuple_size(entry) > 0 and is_atom(elem(entry, 0)) ->
        Atom.to_string(elem(entry, 0))

      entry when is_tuple(entry) and tuple_size(entry) > 0 ->
        inspect(elem(entry, 0), limit: 5)

      other ->
        inspect(other, limit: 5)
    end)

  lines =
    for {key, entries} <- Enum.sort(grouped) do
      hash = :crypto.hash(:sha256, :erlang.term_to_binary(entries, [:deterministic]))
      [key, ?\\t, Base.encode16(hash), ?\\n]
    end

  File.write!(System.fetch_env!("NCC_SCRIPT_OUT"), lines)
  """

  @type result :: {:ok, [String.t()]} | {:differs, String.t(), String.t()} | {:error, String.t()}

  @doc "The command words a Mix user's line holds (`Differential`'s `high` variant too)."
  @spec words() :: [String.t()]
  def words, do: @words

  @doc """
  Checks each `{app, tarball}` (the verified Hex tarball's bytes) whose
  tarball holds a `rebar.config.script`; `{:ok, apps}` names those checked.
  `opts`: `env:` and `extra_env:`, the build's, which every evaluation
  runs in.
  """
  @spec run([{String.t(), binary()}], keyword()) :: result()
  def run(scripts, opts) do
    with {:ok, timeout} <- executable("timeout"),
         {:ok, elixir} <- executable("elixir") do
      env = Keyword.get(opts, :env, []) ++ Keyword.get(opts, :extra_env, [])
      Enum.reduce_while(scripts, {:ok, []}, &checked(&1, &2, {timeout, elixir}, env))
    end
  rescue
    e -> {:error, "script check failed: " <> Exception.message(e)}
  end

  defp checked({app, bytes}, {:ok, done}, exes, env) do
    case check(app, bytes, exes, env) do
      :skip -> {:cont, {:ok, done}}
      :ok -> {:cont, {:ok, done ++ [app]}}
      other -> {:halt, other}
    end
  end

  defp executable(name) do
    case System.find_executable(name) do
      nil -> {:error, "no #{name} on the PATH"}
      path -> {:ok, path}
    end
  end

  # `dir` is a fresh directory this function names under the temp dir, and
  # the only one it removes.
  # sobelow_skip ["Traversal.FileModule"]
  defp check(app, bytes, exes, env) do
    with {:ok, files} <- contents(bytes),
         true <- Map.has_key?(files, "rebar.config.script") do
      dir = Path.join(System.tmp_dir!(), "ncc-sc#{System.unique_integer([:positive])}")

      try do
        tree = Path.join(dir, "tree")
        :ok = write_tree(tree, files)
        script = Path.join(dir, "eval.exs")
        File.write!(script, @eval)
        evaluate(app, literals(files), {dir, tree, script}, exes, env)
      after
        File.rm_rf(dir)
      end
    else
      false -> :skip
      {:error, why} -> {:error, "#{app}: #{why}"}
    end
  end

  # The verified tarball's regular files, `rel => bytes`, by safe relative
  # names only.
  defp contents(bytes) do
    with {:ok, tar} <- Rebar.contents_tar(bytes),
         {:ok, entries} when length(entries) <= @max_files <-
           :erl_tar.extract({:binary, tar}, [:memory]) do
      files =
        for {name, body} <- entries,
            {:ok, rel} <- [Path.safe_relative(List.to_string(name))],
            rel != "",
            into: %{},
            do: {rel, body}

      {:ok, files}
    else
      _ -> {:error, "verified tarball unreadable"}
    end
  rescue
    _ -> {:error, "verified tarball unreadable"}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_tree(tree, files) do
    Enum.each(files, fn {rel, body} ->
      path = Path.join(tree, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end)
  end

  @doc false
  # The string literals of the scripts in `files` (`rel => bytes`): plain
  # printable ones without escapes, sorted, at most `@max_literals`.
  @spec literals(%{String.t() => binary()}) :: [String.t()]
  def literals(files) do
    for {rel, body} <- files,
        script?(rel),
        byte_size(body) <= @max_script_bytes,
        [_, literal] <- Regex.scan(@literal, body),
        byte_size(literal) <= @max_literal_bytes,
        Regex.match?(@plain, literal),
        uniq: true do
      literal
    end
    |> Enum.sort()
    |> Enum.take(@max_literals)
  end

  defp script?(rel), do: rel == "rebar.config.script" or String.ends_with?(rel, ".script")

  defp evaluate(app, literals, paths, exes, env) do
    runs =
      [{"no arguments", []}, {"the traced compile's", @trace_args}] ++
        [{"command words and literals", @words ++ literals}] ++
        Enum.map(literals, &{inspect(&1), [&1]})

    Enum.reduce_while(runs, nil, fn {what, args}, first ->
      case eval(paths, exes, env, args) do
        {:ok, config} when first == nil ->
          {:cont, config}

        {:ok, ^first} ->
          {:cont, first}

        {:ok, config} ->
          {:halt, {:differs, app, "#{differing(first, config)} differs with #{what}"}}

        {:error, why} ->
          {:halt, {:error, "#{app}: #{why} (#{what})"}}
      end
    end)
    |> case do
      %{} -> :ok
      other -> other
    end
  end

  defp differing(a, b) do
    (Map.keys(a) ++ Map.keys(b))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.find(&(Map.get(a, &1) != Map.get(b, &1)))
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp eval({dir, tree, script}, {timeout, elixir}, env, args) do
    out = Path.join(dir, "out-#{System.unique_integer([:positive])}")
    argv = ["--kill-after=5", "#{@timeout_sec}", elixir, script | args]

    case System.cmd(timeout, argv,
           cd: tree,
           env: env ++ [{"NCC_SCRIPT_OUT", out}],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> read_out(out)
      {_out, status} -> {:error, "evaluation exited #{status}"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_out(out) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_out_bytes <-
           File.lstat(out),
         {:ok, text} <- File.read(out) do
      lines = String.split(text, "\n", trim: true)
      parsed = for line <- lines, [key, hash] <- [String.split(line, "\t")], do: {key, hash}

      if length(parsed) == length(lines),
        do: {:ok, Map.new(parsed)},
        else: {:error, "evaluation wrote something else"}
    else
      _ -> {:error, "evaluation wrote no config"}
    end
  end
end
