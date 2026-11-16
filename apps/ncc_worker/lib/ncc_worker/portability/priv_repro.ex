defmodule NccWorker.Portability.PrivRepro do
  @moduledoc """
  Judge revision 21: the second build that lets a package's own compile
  write into its own build `priv`.

  `Events` observes those writes (`priv_writes`) and the probes
  `File.mkdir_p/1` makes of the directories above that `priv`
  (`priv_probes`) instead of refusing them, for the package's own compile
  only: never its `mix.exs`, never a dependency's window, never another
  package writing into the package's `priv` (a kino_db compile packing its
  assets into kino's). Whatever the package wrote there is published as
  its priv files, so it must be what a user's own compile writes. The trace
  shows every read that compile made was a recorded input or allowed; what
  it cannot show is a value no read returns: the clock, a random number,
  the path it was built at. So the package is built a second time:

    * `hold/2` turns a passing verdict with any such observation into a
      could-not-judge that carries what the pass would have said
      (`priv_repro`), so a caller that judges a trace alone
      (`NccWorker.Portability.judge/5`) never publishes it;
    * `settle/6` (`NccWorker.Portability.run/3`) waits a little over a
      second, then runs the traced compile of the package's closure again
      in judge mode into a fresh build path under the system temp dir,
      which must share no directory with the first build's but `/` (the
      worker's `/tmp` and `/work`), else the verdict is could-not-judge;
    * that second trace must pass the judge, its own priv writes and
      probes held as the first's were: a path the package named itself
      (above the first build, or the first build's `priv`) is no directory
      above the second's own `priv`, so it refuses there;
    * the two `priv` trees must be the same: the same relative paths, only
      directories and regular files, the same permission bits and the same
      bytes. A file that holds the time, a random value or the build path
      differs. One exception: a `.tar` or `.tar.gz` whose two copies differ
      in their members' times and the gzip header's `MTIME` and `OS` alone
      (`TarTimes`: `:erl_tar` stamps members with the wall clock, as kino's
      asset archives are), which `priv_tar_times` names and
      `trace_stats["priv_repro"]` marks `"same_but_tar_times"`; the first
      build's bytes are published;
    * the first build's package dir must hash the same before and after
      the second build ran.

  Then the verdict is the pass it held, with `built_priv`: the files the
  package's own compile wrote, which `NccWorker.StaticPriv` publishes
  although its Hex tarball does not carry them. Two different `priv` trees
  refuse with `Compatibility.Portability.priv_not_reproduced/0`, a second
  build refused names its reason after it, and a second build that could
  not be judged, or a first build that changed, is could-not-judge
  (transient when the second compile did not finish). The second build's
  directory is removed either way. Never raises.

  Clock values coarser than the gap (a date) and values the same on every
  build of one machine are not caught by building twice; the trace already
  refuses or records every read of the host.
  """

  alias Compatibility.Portability, as: Reasons
  alias NccWorker.Portability.{Context, TarTimes}

  @gap_ms 1_100
  @hold_problem "own priv writes wait for a second build"
  @max_entries 2_000
  @max_bytes 64 * 1024 * 1024

  @doc "The problem a held verdict carries until `settle/6` decides it."
  @spec hold_problem() :: String.t()
  def hold_problem, do: @hold_problem

  @doc """
  A passing `verdict` as it stands when the package's own compile did
  nothing in or above its own build `priv` (`own.observed?` false), with
  `built_priv: []`. Otherwise could-not-judge, holding the pass's
  `compile_env`, `compile_inputs` and `built_priv` (`own.built`) and the
  package's `priv` and build dirs in `priv_repro` for `settle/6`.
  """
  @spec hold(map(), map()) :: map()
  def hold(verdict, %{observed?: false}), do: Map.put(verdict, :built_priv, [])

  def hold(verdict, own) do
    held = %{
      compile_env: verdict.compile_env,
      compile_inputs: verdict.compile_inputs,
      built_priv: own.built,
      dir: own.dir,
      build: own.build
    }

    %{verdict | status: :skip, reason: Reasons.could_not_judge(), compile_env: nil}
    |> Map.put(:compile_inputs, nil)
    |> Map.put(:priv_repro, held)
    |> update_problems(&(&1 ++ [@hold_problem]))
  end

  @doc """
  Decides a verdict `hold/2` held by building the package again (see the
  moduledoc); any other verdict is returned as it is, and so is every
  verdict when `opts[:priv_repro]` is `false` (the second build itself).
  `run` is `NccWorker.Portability.run/3`; `digest` hashes a build dir
  (`{:ok, digest}` or `{:error, why}`). `opts` are `run/3`'s, plus
  `repro_gap_ms:` and `repro_root:` (tests).
  """
  @spec settle(map(), String.t(), String.t(), keyword(), fun(), fun()) :: map()
  def settle(%{priv_repro: held} = verdict, project_dir, package, opts, run, digest)
      when is_map(held) do
    if Keyword.get(opts, :priv_repro) == false,
      do: verdict,
      else: reproduce(verdict, held, project_dir, package, opts, run, digest)
  rescue
    e -> could_not_judge(verdict, "second build failed: " <> Exception.message(e), false)
  end

  def settle(verdict, _project_dir, _package, _opts, _run, _digest), do: verdict

  # `root` is a fresh directory this function names under the temp dir, and
  # the only one it removes.
  # sobelow_skip ["Traversal.FileModule"]
  defp reproduce(verdict, held, project_dir, package, opts, run, digest) do
    base = Keyword.get_lazy(opts, :repro_root, &System.tmp_dir!/0)
    root = Path.join(base, "ncc-priv-repro-#{System.unique_integer([:positive])}")

    if disjoint?(base, held.build),
      do: reproduce_in(verdict, held, project_dir, package, opts, run, digest, root),
      else: could_not_judge(verdict, "second build path shares a directory with the first", false)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp reproduce_in(verdict, held, project_dir, package, opts, run, digest, root) do
    try do
      # So a clock read to the second differs between the two builds.
      Process.sleep(Keyword.get(opts, :repro_gap_ms, @gap_ms))
      before = digest.(held.build)
      second = run.(project_dir, package, second_opts(opts, root))
      later = digest.(held.build)
      app = Path.basename(held.build)

      decide(
        verdict,
        held,
        second,
        {before, later},
        Path.join([root, "build", "lib", app, "priv"])
      )
    after
      File.rm_rf(root)
    end
  end

  # The second build's root and the first build share no directory but `/`
  # (real paths, compared by their first component), so no directory above
  # one build's `priv` is above the other's: a probe the package aimed at a
  # path of its own choosing is refused in one of them.
  defp disjoint?(base, build) when is_binary(base) and is_binary(build) do
    case {Context.realpath(base), Context.realpath(build)} do
      {"/" <> a, "/" <> b} -> top(a) != top(b)
      _ -> false
    end
  end

  defp disjoint?(_base, _build), do: false

  defp top(path), do: path |> String.split("/", parts: 2) |> hd()

  # The first build's opts with a fresh build path under `root`, its own
  # trace dir and log there, judge mode, its own tree snapshot (the first
  # build's is of a build dir that is no longer empty) and no second build
  # of its own.
  defp second_opts(opts, root) do
    build_path = Path.join(root, "build")

    opts
    |> Keyword.drop([:trees, :trace_dir, :log_file, :mode, :env, :extra_env])
    |> Keyword.merge(
      env: build_path(Keyword.fetch!(opts, :env), build_path, true),
      extra_env: build_path(Keyword.get(opts, :extra_env, []), build_path, false),
      mode: :judge,
      trace_dir: Path.join(root, "trace"),
      log_file: Path.join(root, "compile.log"),
      priv_repro: false
    )
  end

  defp build_path(env, path, always?) do
    if always? or List.keymember?(env, "MIX_BUILD_PATH", 0),
      do: List.keystore(env, "MIX_BUILD_PATH", 0, {"MIX_BUILD_PATH", path}),
      else: env
  end

  defp decide(verdict, held, second, digests, second_priv) do
    cond do
      unfinished?(second) ->
        could_not_judge(verdict, "second build did not finish: #{second_problem(second)}", true)

      not second_passed?(second) ->
        second_refused(verdict, second)

      not same_digest?(digests) ->
        could_not_judge(verdict, "the first build changed while the second ran", false)

      true ->
        compare(verdict, held, held.dir, second_priv)
    end
  end

  defp unfinished?(second),
    do: get_in(second, [:observations, "trace_stats", "judge_compile"]) != "finished"

  # Passed, or held for its own second build, which it does not get: then
  # its only problem is the hold.
  defp second_passed?(%{status: :pass}), do: true

  defp second_passed?(%{priv_repro: held} = second) when is_map(held),
    do: (get_in(second, [:observations, "problems"]) || []) == [@hold_problem]

  defp second_passed?(_second), do: false

  defp second_refused(verdict, %{reason: reason} = second) do
    if reason == Reasons.could_not_judge(),
      do: could_not_judge(verdict, "second build: #{second_problem(second)}", false),
      else: refuse(verdict, "a second build refused (#{reason})")
  end

  defp second_problem(second) do
    stats = get_in(second, [:observations, "trace_stats"]) || %{}
    problems = get_in(second, [:observations, "problems"]) || []
    Enum.join([stats["tracer_error"] | problems] |> Enum.filter(&is_binary/1), "; ")
  end

  defp same_digest?({{:ok, digest}, {:ok, digest}}), do: true
  defp same_digest?(_digests), do: false

  # Every difference must be a `.tar` or `.tar.gz` file whose times alone
  # differ (`TarTimes`); those are named in `priv_tar_times`.
  defp compare(verdict, held, first_priv, second_priv) do
    with {:ok, first} <- tree(first_priv),
         {:ok, second} <- tree(second_priv) do
      {times, other} =
        first
        |> differences(second)
        |> Enum.split_with(&times_only?(&1, first, second, first_priv, second_priv))

      case other do
        [] -> verdict |> pass(held) |> put_tar_times(times)
        [rel | _] -> refuse(verdict, "priv/#{rel} differs between two builds")
      end
    else
      {:error, why} -> could_not_judge(verdict, "priv could not be compared: #{why}", false)
    end
  end

  defp differences(first, second) do
    (Map.keys(first) ++ Map.keys(second))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.filter(&(Map.get(first, &1) != Map.get(second, &1)))
  end

  # Both regular files with the same permission bits, each still the bytes
  # the walk hashed, that differ in their tar times alone.
  defp times_only?(rel, first, second, first_priv, second_priv) do
    with {:file, perm, sum_a} <- Map.get(first, rel),
         {:file, ^perm, sum_b} <- Map.get(second, rel),
         {:ok, a} <- read_hashed(Path.join(first_priv, rel), sum_a),
         {:ok, b} <- read_hashed(Path.join(second_priv, rel), sum_b) do
      TarTimes.same?(rel, a, b)
    else
      _ -> false
    end
  end

  # A file the walk read and hashed, read again under the same caps.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_hashed(path, sum) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes <-
           File.lstat(path),
         {:ok, bytes} <- File.read(path),
         true <- :crypto.hash(:sha256, bytes) == sum do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp put_tar_times(verdict, []), do: verdict

  defp put_tar_times(%{observations: obs} = verdict, rels) do
    obs =
      obs
      |> Map.put("priv_tar_times", Enum.take(rels, 50))
      |> Map.update("trace_stats", %{}, &Map.put(&1, "priv_repro", "same_but_tar_times"))

    %{verdict | observations: obs}
  end

  # `rel => {:dir, mode} | {:file, mode, sha256}` for everything under
  # `dir`, read with `lstat` so a link is seen as one (and refused). No
  # `dir` at all is an empty tree. Bounded in entries and bytes.
  # sobelow_skip ["Traversal.FileModule"]
  defp tree(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} -> walk(dir, "", {:ok, %{}, 0})
      {:error, :enoent} -> {:ok, %{}}
      {:ok, _other} -> {:error, "priv is not a directory"}
      {:error, why} -> {:error, "priv: #{inspect(why)}"}
    end
    |> case do
      {:ok, tree, _bytes} -> {:ok, tree}
      other -> other
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp walk(root, rel, acc) do
    case File.ls(Path.join(root, rel)) do
      {:ok, names} ->
        names |> Enum.sort() |> Enum.reduce_while(acc, &entry(root, join(rel, &1), &2))

      {:error, why} ->
        {:error, "#{rel}: #{inspect(why)}"}
    end
  end

  defp entry(_root, _rel, {:ok, tree, _bytes}) when map_size(tree) >= @max_entries,
    do: {:halt, {:error, "over #{@max_entries} entries"}}

  # sobelow_skip ["Traversal.FileModule"]
  defp entry(root, rel, {:ok, tree, bytes}) do
    path = Path.join(root, rel)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        {:cont, walk(root, rel, {:ok, Map.put(tree, rel, {:dir, perm(mode)}), bytes})}
        |> halted()

      {:ok, %File.Stat{type: :regular, size: size, mode: mode}}
      when bytes + size <= @max_bytes ->
        file(path, rel, size, mode, tree, bytes)

      {:ok, %File.Stat{type: :regular}} ->
        {:halt, {:error, "over #{@max_bytes} bytes"}}

      {:ok, %File.Stat{type: type}} ->
        {:halt, {:error, "priv/#{rel} is a #{type}"}}

      {:error, why} ->
        {:halt, {:error, "priv/#{rel}: #{inspect(why)}"}}
    end
  end

  defp halted({:cont, {:error, _} = error}), do: {:halt, error}
  defp halted(cont), do: cont

  # Its bytes, no more than the size `lstat` gave: a file that grew since is
  # not the file that was walked.
  # sobelow_skip ["Traversal.FileModule"]
  defp file(path, rel, size, mode, tree, bytes) do
    case File.open(path, [:read, :raw, :binary], &IO.binread(&1, size + 1)) do
      {:ok, data} when is_binary(data) and byte_size(data) == size ->
        sum = :crypto.hash(:sha256, data)
        {:cont, {:ok, Map.put(tree, rel, {:file, perm(mode), sum}), bytes + size}}

      {:ok, :eof} when size == 0 ->
        {:cont, {:ok, Map.put(tree, rel, {:file, perm(mode), :crypto.hash(:sha256, "")}), bytes}}

      _ ->
        {:halt, {:error, "priv/#{rel} could not be read"}}
    end
  end

  defp perm(mode), do: Bitwise.band(mode, 0o7777)

  defp join("", name), do: name
  defp join(rel, name), do: rel <> "/" <> name

  defp pass(verdict, held) do
    %{verdict | status: :pass, reason: nil, compile_env: held.compile_env}
    |> Map.put(:compile_inputs, held.compile_inputs)
    |> Map.put(:built_priv, held.built_priv)
    |> Map.delete(:priv_repro)
    |> update_problems(&List.delete(&1, @hold_problem))
    |> put_repro("same")
  end

  defp refuse(verdict, why) do
    %{verdict | status: :skip, reason: Reasons.priv_not_reproduced() <> why}
    |> Map.delete(:priv_repro)
    |> update_problems(&List.delete(&1, @hold_problem))
    |> put_repro("differs")
  end

  defp could_not_judge(verdict, why, transient?) do
    %{verdict | status: :skip, reason: Reasons.could_not_judge()}
    |> Map.delete(:priv_repro)
    |> update_problems(&(List.delete(&1, @hold_problem) ++ [why]))
    |> put_repro(if(transient?, do: "not_finished", else: "not_judged"))
  end

  defp update_problems(%{observations: obs} = verdict, fun),
    do: %{verdict | observations: Map.put(obs, "problems", fun.(obs["problems"] || []))}

  # `trace_stats["priv_repro"]`: `"same"` (or `"same_but_tar_times"`,
  # `put_tar_times/2`), `"differs"`, `"not_finished"`
  # (transient: the portal builds it again) or `"not_judged"`.
  defp put_repro(%{observations: obs} = verdict, outcome) do
    stats = Map.put(obs["trace_stats"] || %{}, "priv_repro", outcome)
    %{verdict | observations: Map.put(obs, "trace_stats", stats)}
  end
end
