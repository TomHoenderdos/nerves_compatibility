defmodule NccWorker.Portability.ScriptCheck do
  @moduledoc """
  The script check of a differential build (`NccWorker.Portability.Differential`):
  whether a rebar3 dependency's `rebar.config.script` gives the same config
  whatever plain arguments Mix's VM was started with.

  Mix evaluates the script in its own VM when it loads the dependencies
  (`Mix.Rebar.load_config/1` from `Mix.Dep.Loader`), so the script sees
  that VM's plain arguments (`[mix, task | args]` for a user, `["--no-halt",
  "+iex", "-S", "mix", ...]` under `iex -S mix`), and Mix, Mix.Project and
  Hex loaded (tls_certificate_check's script branches on that). A script
  tests the arguments against literals of its own (gproc's
  `lists:member("doc", Args)`), which no list of command words can guess.

  So the check runs the same kind of VM in the run's own project: `elixir
  -pa <ebin> -S mix ncc.script_eval <words>`, the build's env with a fresh
  build path of its own, cwd the project; the task
  (`Elixir.Mix.Tasks.Ncc.ScriptEval`, `src/`) calls `Mix.Dep.load_and_cache/0`
  as the traced compile's driver does and writes, per app asked, the config
  Mix writes as its `mix.rebar.config`, hashed whole, and a hash per
  top-level key but `deps`. The evaluations:

    * no words after the task, as the traced compile has none: every app's
      config must be exactly the `mix.rebar.config` the first build wrote
      (`<build_root>/lib/<app>/mix.rebar.config`, review B2), else the
      check's VM is not the build's and the check refuses; an app with no
      such file refuses too;
    * the command words of a Mix user's line (`words/0`, `iex`'s included)
      and every string literal of the apps' `rebar.config.script` and
      `*.script` files at once, then each literal alone (at most
      `@max_literals` in all): every config must be the first
      evaluation's, key by key, but for `deps`. A rebar3 dependency's
      `deps` never reaches its own compile (`rebar3 bare compile` fetches
      and builds nothing; Mix hands it the code path of the tree the user's
      lock resolved), and gproc's `"doc"` adds a git `edown` there alone.

  The scripts are package code: they run in VMs under `timeout(1)`, the
  task's instructions and output in a fresh dir this module makes
  exclusively and removes, and nothing they print is trusted beyond the
  lines asked for, read under a cap. Their side effects outside it are
  what the variant builds' sweeps, tree checks and the first build's digest
  check are for. Never raises.
  """

  alias NccWorker.Portability.Rebar

  @task :"Elixir.Mix.Tasks.Ncc.ScriptEval"
  @max_literals 24
  @max_literal_bytes 64
  @max_files 10_000
  @max_script_bytes 1024 * 1024
  @max_out_bytes 1024 * 1024
  @timeout_sec 60
  @default_budget_ms 5 * 60 * 1000
  # Mix task words a Mix user's command line holds that rebar3 scripts test
  # their arguments against, as rebar3 command names, and what `iex -S mix`
  # puts there (review B2).
  @words ~w(compile test deps.compile deps.get release docs run xref dialyzer eunit ct
            escript.build phx.server prod --force iex +iex --no-halt)
  # A whole Erlang string literal, escapes included, so one with an escape
  # is skipped as one rather than read from its middle.
  @literal ~r/"((?:[^"\\\n]|\\.)*)"/
  @plain ~r/\A[\x20-\x21\x23-\x5b\x5d-\x7e]{1,64}\z/

  @type result :: {:ok, [String.t()]} | {:differs, String.t(), String.t()} | {:error, String.t()}

  @doc "The command words a Mix user's line holds (`Differential`'s `high` variant too)."
  @spec words() :: [String.t()]
  def words, do: @words

  @doc """
  Checks each `{app, tarball}` (the verified Hex tarball's bytes) whose
  tarball holds a `rebar.config.script`; `{:ok, apps}` names those checked.
  `opts`: `env:` and `extra_env:`, the build's, which every evaluation runs
  in; `project_dir:`, the run's project; `build_root:`, the first build's
  `MIX_BUILD_PATH`, which holds its `mix.rebar.config` files; `budget_ms:`,
  one wall budget for every evaluation together (default 5 minutes): each
  evaluation's timeout is cut to what is left of it, and the check stops
  with `{:error, "over its time budget ..."}` once nothing is.
  """
  @spec run([{String.t(), binary()}], keyword()) :: result()
  def run(scripts, opts) do
    with {:ok, scripted} <- scripted(scripts) do
      if scripted == [], do: {:ok, []}, else: check(scripted, opts)
    end
  rescue
    e -> {:error, "script check failed: " <> Exception.message(e)}
  end

  # The apps whose tarball holds a script, with their literals.
  defp scripted(scripts) do
    Enum.reduce_while(scripts, {:ok, []}, fn {app, bytes}, {:ok, acc} ->
      case contents(bytes) do
        {:ok, %{"rebar.config.script" => _} = files} ->
          {:cont, {:ok, acc ++ [{app, literals(files)}]}}

        {:ok, _files} ->
          {:cont, {:ok, acc}}

        {:error, why} ->
          {:halt, {:error, "#{app}: #{why}"}}
      end
    end)
  end

  defp check(scripted, opts) do
    apps = Enum.map(scripted, &elem(&1, 0))

    with {:ok, anchors} <- anchors(apps, Keyword.fetch!(opts, :build_root)),
         {:ok, timeout} <- executable("timeout"),
         {:ok, elixir} <- executable("elixir") do
      literals =
        scripted |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq() |> Enum.take(@max_literals)

      budget = Keyword.get(opts, :budget_ms, @default_budget_ms)

      opts =
        Keyword.merge(opts,
          deadline: System.monotonic_time(:millisecond) + budget,
          budget_s: div(budget, 1000)
        )

      in_scratch(apps, fn paths ->
        evaluate(apps, anchors, literals, paths, {timeout, elixir}, opts)
      end)
    end
  end

  # Each app's first-build `mix.rebar.config`, sha256 in hex.
  # sobelow_skip ["Traversal.FileModule"]
  defp anchors(apps, build_root) do
    Enum.reduce_while(apps, {:ok, %{}}, fn app, {:ok, acc} ->
      path = Path.join([build_root, "lib", app, "mix.rebar.config"])

      with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_out_bytes <-
             File.lstat(path),
           {:ok, bytes} <- File.read(path) do
        {:cont, {:ok, Map.put(acc, app, sha(bytes))}}
      else
        _ -> {:halt, {:differs, app, "no mix.rebar.config of the first build to reproduce"}}
      end
    end)
  end

  defp sha(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp executable(name) do
    case System.find_executable(name) do
      nil -> {:error, "no #{name} on the PATH"}
      path -> {:ok, path}
    end
  end

  # A fresh dir made exclusively under the temp dir, holding the task's
  # beam and instructions (`ebin/`), its output and an empty build path;
  # the only dir this module removes.
  # sobelow_skip ["Traversal.FileModule"]
  defp in_scratch(apps, fun) do
    base =
      Path.join(
        System.tmp_dir!(),
        "ncc-sc-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    case File.mkdir(base) do
      :ok ->
        try do
          ebin = Path.join(base, "ebin")
          build = Path.join(base, "build")
          out = Path.join(base, "out")
          File.mkdir!(ebin)
          File.mkdir!(build)
          File.write!(Path.join(ebin, "#{@task}.beam"), object_code!(@task))
          instructions = %{apps: apps, out: out}
          File.write!(Path.join(ebin, "script_eval.etf"), :erlang.term_to_binary(instructions))
          fun.(%{ebin: ebin, build: build, out: out})
        after
          File.rm_rf(base)
        end

      {:error, why} ->
        {:error, "no fresh scratch dir: #{inspect(why)}"}
    end
  end

  defp object_code!(module) do
    case :code.get_object_code(module) do
      {^module, binary, _file} -> binary
      :error -> module |> :code.which() |> List.to_string() |> File.read!()
    end
  end

  defp evaluate(apps, anchors, literals, paths, exes, opts) do
    runs =
      [{"command words and literals", @words ++ literals}] ++
        Enum.map(literals, &{inspect(&1), [&1]})

    with {:ok, first} <- eval(paths, exes, opts, []),
         :ok <- anchored(apps, anchors, first) do
      Enum.reduce_while(runs, {:ok, apps}, &next_run(&1, &2, apps, first, paths, exes, opts))
    end
  end

  defp next_run({what, words}, ok, apps, first, paths, exes, opts) do
    case compare_run(apps, first, eval(paths, exes, opts, words), what) do
      :ok -> {:cont, ok}
      other -> {:halt, other}
    end
  end

  defp compare_run(apps, first, {:ok, other}, what) do
    case same_keys(apps, first, other) do
      :ok -> :ok
      {:differs, app, key} -> {:differs, app, "#{key} differs with #{what}"}
    end
  end

  defp compare_run(_apps, _first, {:error, why}, what), do: {:error, "#{why} (#{what})"}

  # The evaluation with no words must give each app exactly its first
  # build's `mix.rebar.config`.
  defp anchored(apps, anchors, first) do
    case Enum.find(apps, &(get_in(first, [&1, :full]) != Map.fetch!(anchors, &1))) do
      nil ->
        :ok

      app ->
        {:differs, app,
         "the check's evaluation does not reproduce the first build's mix.rebar.config"}
    end
  end

  defp same_keys(apps, first, other) do
    Enum.find_value(apps, :ok, fn app ->
      a = get_in(first, [app, :keys]) || %{}
      b = get_in(other, [app, :keys]) || %{}

      case (Map.keys(a) ++ Map.keys(b))
           |> Enum.uniq()
           |> Enum.sort()
           |> Enum.find(&(a[&1] != b[&1])) do
        nil -> nil
        key -> {:differs, app, key}
      end
    end)
  end

  defp eval(paths, exes, opts, words) do
    case div(Keyword.fetch!(opts, :deadline) - System.monotonic_time(:millisecond), 1000) do
      left when left >= 1 -> eval(paths, exes, opts, words, min(left, @timeout_sec))
      _ -> {:error, "over its time budget of #{Keyword.fetch!(opts, :budget_s)} s"}
    end
  end

  # sobelow_skip ["CI.System", "Traversal.FileModule"]
  defp eval(%{ebin: ebin, build: build, out: out}, {timeout, elixir}, opts, words, seconds) do
    _ = File.rm(out)

    env =
      (Keyword.get(opts, :env, []) ++ Keyword.get(opts, :extra_env, []))
      |> List.keystore("MIX_BUILD_PATH", 0, {"MIX_BUILD_PATH", build})

    argv = [
      "--kill-after=5",
      "#{seconds}",
      elixir,
      "-pa",
      ebin,
      "-S",
      "mix",
      "ncc.script_eval" | words
    ]

    case System.cmd(timeout, argv,
           cd: Keyword.fetch!(opts, :project_dir),
           env: env,
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        read_out(out)

      {_out, status} when status in [124, 137] ->
        {:error, "evaluation timed out after #{seconds} s"}

      {_out, status} ->
        {:error, "evaluation exited #{status}"}
    end
  end

  # `app => %{full: hash, keys: %{key => hash}}`, from the task's lines.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_out(out) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_out_bytes <-
           File.lstat(out),
         {:ok, text} <- File.read(out) do
      text |> String.split("\n", trim: true) |> Enum.reduce_while({:ok, %{}}, &line/2)
    else
      _ -> {:error, "evaluation wrote no config"}
    end
  end

  defp line(line, {:ok, acc}) do
    case String.split(line, "\t") do
      [app, "full", hash] ->
        {:cont, {:ok, Map.update(acc, app, %{full: hash, keys: %{}}, &Map.put(&1, :full, hash))}}

      [app, "key", key, hash] ->
        {:cont,
         {:ok,
          Map.update(
            acc,
            app,
            %{full: nil, keys: %{key => hash}},
            &put_in(&1, [:keys, key], hash)
          )}}

      _ ->
        {:halt, {:error, "evaluation wrote something else"}}
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
end
