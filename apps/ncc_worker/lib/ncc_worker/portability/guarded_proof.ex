defmodule NccWorker.Portability.GuardedProof do
  @moduledoc """
  The build that proves a guarded-module waiver (`NccWorker.Portability.Guarded`,
  coverage drop 2026-11-22, F4; S9 fix round 1). `Guarded`'s conditions
  are a pre-filter only: the review found two ways a dependent sees a
  guarded module that no static condition lists (the type checker reading
  its signature through a value of its atom's type, and a read of the
  prober's Mix manifest). So the waiver is granted only when the package
  built with the guarded package present is the package built without it:

    * `hold/3` turns a passing verdict with any waiver into a
      could-not-judge that carries what the pass would have said
      (`guarded`), so a caller that judges a trace alone never publishes
      it. A verdict `PrivRepro` or `Differential` holds as well is
      could-not-judge for good: they are not settled together;
    * `settle/5` (`NccWorker.Portability.run/3`) builds one world per
      non-empty subset of the waived entries (S9 re-review R1-1): a user's
      world is any presence vector over them, each entry's guarded package
      present or not, the all-absent one being the first build. That is
      `2^n - 1` worlds, smallest first; more than three waived entries
      refuse (at most 7 worlds). Each world is built at the first build's
      own paths, so no path in a beam can differ: the real project dir
      (`Context.realpath/1`, R1-3) is renamed aside whole (its `_build` and
      `deps` with it), and a fresh copy of it without `_build` takes its
      place for each world. Into that copy's `mix.exs` go the subset's
      guarded packages (`present`: cowboy for
      websock_adapter, poison for jose, decimal for ymlr), `mix deps.get`
      fetches them, and every release of the first lock must be locked the
      same (a version conflict refuses). Its project gets
      `prune_code_paths: false`, as Mix.install's has. Then the traced
      compile of the package's closure runs there (`NccWorker.Tracer`,
      judge mode), with the guarded packages' closure compiled first: on a
      code path no dependency's compile prunes, the prober finds the probed
      module and builds its guarded modules, which must then be in its
      ebin, and no guarded module of an entry outside the subset may be
      (else the world is not the vector it stands for and refuses);
    * the package's app of every world must be the first build's
      (`compare_app/2`): the same ebin file names, every non-beam file the
      same bytes, every beam the same chunk ids in the same order and every
      chunk the same bytes, but for `Dbgi`, `ExCk` and `Docs`, which must
      decode to the same terms (their map keys are written in an order the
      compiling VM's atom table decides, `NccWorker.BuildIdentity`); and the
      same `priv` tree (paths, types, permission bits, bytes, link targets);
    * the copy is removed and the first project put back under its own
      name, and the first build's app must hash the same as before.

  Then the verdict is the pass it held, with `trace_stats["guarded_proof"]`
  saying so. Anything else refuses with the taint the waiver lifted, and
  `observations["problems"]` says why: a different app, a second compile
  that failed or did not finish, a guarded package that could not be added,
  guarded modules that were not built, a build or deps dir outside the
  project dir, a first build that changed. Never raises.

  Each world adds the guarded package at the newest release that resolves
  against the lock. Another release is no other world for the three
  entries (S9 re-review Q2, R1-5), because the guarded modules' beams
  depend only on whether the probed module is found: the prober declares
  no dependency on its guarded package, so its type checker reads no
  signature of it (Elixir 1.20 infers signatures only from the compiling
  project's own dependency apps), and the guarded code uses the package
  only at run time or for a warning (each entry's comment in `Guarded`
  says how). A dependent sees the guarded package's own modules only
  through traced probes, which the first build judged. A new entry's
  review must check the same: an entry whose guarded code uses its package
  at compile time (`use`, `require`, a struct, `@derive`), or whose prober
  declares it, needs a world per release, which this module does not build.

  The worlds' traces are recorded but not judged (R1-4). A world's
  compile-time code runs at the project's real path while the first
  project sits beside it, and could write into it; the digest after the
  put-back covers the package's published app (ebin and priv, the link
  followed). Only a deliberate write reaches anything else, which the spec
  leaves out of scope. Each world is one more traced compile of the whole
  closure: one waived entry costs one, two cost three, three cost seven.
  """

  alias Compatibility.Portability, as: Reasons
  alias NccWorker.{DepsLock, Project, Tracer}
  alias NccWorker.Portability.{Context, Differential, Etf, ForeignPriv, Guarded, PrivRepro}

  @hold_problem "guarded modules wait for a build with their package present"
  # 2^3 - 1 = 7 proof worlds at most (S9 re-review R1-1).
  @max_waived 3
  @together "guarded modules and own priv writes are not settled together"
  @with_varied "guarded modules and varied host reads are not settled together"
  @first_suffix ".ncc-guarded-first"
  # The chunks compared as decoded terms (see the moduledoc).
  @decoded ~w(Dbgi ExCk Docs)
  @max_entries 20_000
  @max_file_bytes 256 * 1024 * 1024

  @doc "The problem a held verdict carries until `settle/5` decides it."
  @spec hold_problem() :: String.t()
  def hold_problem, do: @hold_problem

  @doc """
  Holds a passing `verdict` that `waivers` (`Guarded.waivers/3`) lifted a
  taint for (see the moduledoc). `context` holds the package's build dir
  (`build:`, `<build path>/lib/<app>`, or nil) and the closure's apps in
  compile order (`order:`), the first waived one of which names the
  refusal a failed proof gives.
  """
  @spec hold(map(), map(), map()) :: map()
  def hold(verdict, waivers, _context) when map_size(waivers) == 0, do: verdict

  def hold(%{priv_repro: held} = verdict, _waivers, _context) when is_map(held) do
    verdict
    |> Map.delete(:priv_repro)
    |> update_problems(&(List.delete(&1, PrivRepro.hold_problem()) ++ [@together]))
  end

  # S2's differential hold neither: a pass with varied reads and a waiver
  # is could-not-judge for good.
  def hold(%{differential: held} = verdict, _waivers, _context) when is_map(held) do
    verdict
    |> Map.delete(:differential)
    |> update_problems(&(List.delete(&1, Differential.hold_problem()) ++ [@with_varied]))
  end

  def hold(%{status: :pass} = verdict, waivers, context) do
    held = %{
      compile_env: verdict.compile_env,
      compile_inputs: verdict.compile_inputs,
      built_priv: Map.get(verdict, :built_priv),
      foreign_priv: Map.get(verdict, :foreign_priv),
      foreign_priv_rule: Map.get(verdict, :foreign_priv_rule),
      waivers: waivers,
      build: Map.get(context, :build),
      refusal: refusal(waivers, Map.get(context, :order, []))
    }

    %{verdict | status: :skip, reason: Reasons.could_not_judge(), compile_env: nil}
    |> Map.put(:compile_inputs, nil)
    |> Map.put(:guarded, held)
    |> ForeignPriv.unpass()
    |> update_problems(&(&1 ++ [@hold_problem]))
  end

  def hold(verdict, _waivers, _context), do: verdict

  # The taint the first waived dependency in compile order would have
  # given.
  defp refusal(waivers, order) do
    app =
      Enum.find(order, &Map.has_key?(waivers, &1)) || waivers |> Map.keys() |> Enum.min()

    reason = waivers[app].reasons |> Enum.sort() |> hd()
    "closure dependency observed the host: #{app} (#{reason})"
  end

  @doc """
  Decides a verdict `hold/3` held by building the second world (see the
  moduledoc); any other verdict is returned as it is. `digest` hashes a
  build dir (`{:ok, digest}` or `{:error, why}`). `opts` are
  `NccWorker.Portability.run/3`'s, with `guarded_trace_dir:` (the second
  compile's own trace dir), plus `guarded_present:` (`%{entry_id => %{deps:
  [dep tuple source], first: [package]}}`) and `guarded_deps_get:` (tests).
  """
  @spec settle(map(), String.t(), String.t(), keyword(), fun()) :: map()
  def settle(%{guarded: held} = verdict, project_dir, package, opts, digest)
      when is_map(held) do
    started = System.monotonic_time(:millisecond)
    entries = waived_entries(held.waivers, opts)

    result =
      with {:ok, worlds} <- worlds(entries),
           do: prove(held, project_dir, package, worlds, opts, digest)

    ms = System.monotonic_time(:millisecond) - started
    present = %{first: entries |> Enum.flat_map(&elem(&1, 1).first) |> Enum.uniq()}

    case result do
      :ok -> pass(verdict, held, Map.put(present, :worlds, length(subsets(entries))), ms)
      {:refuse, why} -> refuse(verdict, held, why, present, ms)
    end
  rescue
    e ->
      refuse(
        verdict,
        held,
        "the build with the guarded packages failed: " <> Exception.message(e),
        nil,
        nil
      )
  end

  def settle(verdict, _project_dir, _package, _opts, _digest), do: verdict

  # `{entry_id, present}` of every waived entry, once each, sorted by id.
  defp waived_entries(waivers, opts) do
    overrides = Keyword.get(opts, :guarded_present, %{})

    for id <-
          waivers |> Map.values() |> Enum.flat_map(& &1.entries) |> Enum.uniq() |> Enum.sort(),
        entry = Enum.find(Guarded.entries(), &(&1.id == id)),
        entry != nil,
        do: {id, Map.get(overrides, id, entry.present)}
  end

  @doc false
  # Public for tests (S9 re-review R1-1). A user's world is a presence
  # vector over the waived entries: each entry's guarded package present or
  # not. The first build is the all-absent one; every other vector is a
  # non-empty subset, and each is one proof world, `2^n - 1` of them,
  # smallest first. More than `max_entries/0` waived entries refuses
  # rather than build more than 7 worlds (`max_entries/0`).
  @spec worlds([{String.t(), map()}]) :: {:ok, [[{String.t(), map()}]]} | {:refuse, String.t()}
  def worlds(entries) when length(entries) > @max_waived,
    do:
      {:refuse,
       "more than #{@max_waived} guarded entries are waived (#{length(entries)}): " <>
         "not proved"}

  def worlds([]), do: {:refuse, "no guarded entry is waived"}
  def worlds(entries), do: {:ok, subsets(entries)}

  @doc "The most waived entries a proof builds every world for."
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_waived

  defp subsets(entries) do
    entries
    |> Enum.reduce([[]], fn entry, acc -> acc ++ Enum.map(acc, &(&1 ++ [entry])) end)
    |> Enum.reject(&(&1 == []))
    |> Enum.sort_by(&length/1)
  end

  # One world's guarded packages.
  defp present(subset) do
    specs = Enum.map(subset, &elem(&1, 1))

    %{
      ids: Enum.map(subset, &elem(&1, 0)),
      deps: specs |> Enum.flat_map(& &1.deps) |> Enum.uniq(),
      first: specs |> Enum.flat_map(& &1.first) |> Enum.uniq()
    }
  end

  # The real project dir is what moves aside (S9 re-review R1-3): a
  # project dir reached through a link (macOS's `/var`) moves the dir, not
  # the link, and every path compared with it is resolved too.
  defp prove(held, project_dir, package, worlds, opts, digest) do
    case Context.realpath(project_dir) do
      real when is_binary(real) -> prove_in(held, real, package, worlds, opts, digest)
      nil -> {:refuse, "the project dir cannot be resolved"}
    end
  end

  defp prove_in(held, project_dir, package, worlds, opts, digest) do
    first = project_dir <> @first_suffix

    with :ok <- inside(held.build, project_dir, opts),
         held = %{held | build: Context.realpath(held.build)},
         {:ok, before} <- checked_digest(digest, held.build),
         :ok <- absent(first),
         :ok <- move(project_dir, first) do
      result = every_world(held, project_dir, first, package, worlds, opts)

      with :ok <- put_back(project_dir, first),
           :ok <- result,
           {:ok, ^before} <- checked_digest(digest, held.build) do
        :ok
      else
        {:ok, _other} ->
          {:refuse, "the first build changed while the guarded packages were built"}

        other ->
          other
      end
    end
  end

  # Each world in turn, the first that does not prove refusing; the copy
  # each one built in is removed before the next.
  defp every_world(held, project_dir, first, package, worlds, opts) do
    worlds
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {subset, n}, :ok ->
      present = present(subset)

      case guarded_world(held, project_dir, first, package, present, world_opts(opts, n)) do
        :ok ->
          {:cont, clear(project_dir)}

        {:refuse, why} ->
          {:halt, {:refuse, "with #{Enum.join(present.first, ", ")} present: " <> why}}
      end
    end)
  end

  defp world_opts(opts, n),
    do: Keyword.update!(opts, :guarded_trace_dir, &"#{&1}-#{n}")

  # The copy a world built in, so the next world copies afresh.
  # sobelow_skip ["Traversal.FileModule"]
  defp clear(project_dir) do
    case File.rm_rf(project_dir) do
      {:ok, _} -> :ok
      {:error, why, _} -> {:refuse, "a proof world cannot be removed: #{inspect(why)}"}
    end
  end

  # One world, whatever it raises: the first project goes back under its
  # own name in any case (`prove/6`).
  defp guarded_world(held, project_dir, first, package, present, opts) do
    world(held, project_dir, first, package, present, opts)
  rescue
    e -> {:refuse, "the build with the guarded packages failed: " <> Exception.message(e)}
  catch
    kind, reason ->
      {:refuse,
       "the build with the guarded packages failed: #{kind} #{inspect(reason, limit: 5)}"}
  end

  # The first build's app, its build path and its deps dir all lie in the
  # project dir, which is what moves aside.
  # Every path real (`Context.realpath/1`, links followed), `project_dir`
  # already so (S9 re-review R1-3).
  defp inside(build, project_dir, opts) do
    env = Keyword.get(opts, :env, [])

    paths = [
      build,
      env_value(env, "MIX_BUILD_PATH") || Path.join(project_dir, "_build"),
      env_value(env, "MIX_DEPS_PATH") || Path.join(project_dir, "deps")
    ]

    if Enum.all?(paths, &in_project?(&1, project_dir)),
      do: :ok,
      else: {:refuse, "the build or deps dir is not in the project dir"}
  end

  defp in_project?(path, project_dir) when is_binary(path) do
    case Context.realpath(Path.expand(path, project_dir)) do
      real when is_binary(real) -> String.starts_with?(real, project_dir <> "/")
      nil -> false
    end
  end

  defp in_project?(_path, _project_dir), do: false

  defp checked_digest(digest, dir) do
    case digest.(dir) do
      {:ok, value} -> {:ok, value}
      {:error, why} -> {:refuse, "the first build cannot be hashed: #{inspect(why, limit: 5)}"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp absent(path) do
    if File.exists?(path),
      do: {:refuse, "#{Path.basename(path)} exists already"},
      else: :ok
  end

  # The worker's own project dir and the name beside it this module made.
  # sobelow_skip ["Traversal.FileModule"]
  defp move(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, why} -> {:refuse, "the project dir cannot be moved aside: #{inspect(why)}"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp put_back(project_dir, first) do
    File.rm_rf(project_dir)

    case File.rename(first, project_dir) do
      :ok -> :ok
      {:error, why} -> {:refuse, "the first project dir cannot be put back: #{inspect(why)}"}
    end
  rescue
    e -> {:refuse, "the first project dir cannot be put back: " <> Exception.message(e)}
  end

  defp world(held, project_dir, first, package, present, opts) do
    env = Keyword.get(opts, :env, [])
    deps_get = Keyword.get(opts, :guarded_deps_get, &Project.run_deps_get/2)
    trace_dir = Keyword.fetch!(opts, :guarded_trace_dir)

    try do
      with :ok <- copy_project(first, project_dir),
           :ok <- add_present(project_dir, present.deps),
           :ok <- fetched(deps_get.(project_dir, env)),
           :ok <- same_lock(first, project_dir),
           :ok <-
             traced(Tracer.run(project_dir, [package], trace_opts(opts, env, trace_dir, present))),
           :ok <- guarded_built(held, present.ids) do
        compared(compare_app(moved(held.build, project_dir, first), held.build))
      end
    after
      remove(trace_dir)
    end
  end

  # `path` in the moved-aside first project: its real path, `project_dir`
  # (real) replaced by `first`, resolved before the move.
  defp moved(path, project_dir, first),
    do: first <> String.replace_prefix(path, project_dir, "")

  # Every entry of the moved project but `_build`, so the copy compiles
  # from nothing at the first build's own paths.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_project(first, project_dir) do
    with :ok <- File.mkdir(project_dir),
         {:ok, names} <- File.ls(first) do
      names
      |> Enum.reject(&(&1 == "_build"))
      |> Enum.reduce_while(:ok, &copy_entry(&1, &2, first, project_dir))
    else
      {:error, why} -> {:refuse, "the project cannot be copied: #{inspect(why)}"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp copy_entry(name, :ok, first, project_dir) do
    case File.cp_r(Path.join(first, name), Path.join(project_dir, name)) do
      {:ok, _} ->
        {:cont, :ok}

      {:error, why, file} ->
        {:halt, {:refuse, "the project cannot be copied: #{file} #{inspect(why)}"}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp add_present(project_dir, deps) do
    path = Path.join(project_dir, "mix.exs")

    with {:ok, content} <- File.read(path),
         {:ok, added} <- inject(content, deps),
         {:ok, added} <- unpruned(added),
         :ok <- File.write(path, added) do
      :ok
    else
      {:error, why} ->
        {:refuse, "the guarded packages cannot be added to mix.exs: #{inspect(why, limit: 5)}"}
    end
  end

  @doc false
  # Public for tests: `content` (a generated project's `mix.exs`) with each
  # dependency in `deps` (a `{:name, ...}` tuple's source) first in its
  # deps list, the `defp deps do [` block's or a `deps: [` list's. A name
  # already listed is left as it is.
  @spec inject(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def inject(content, deps) do
    Enum.reduce_while(deps, {:ok, content}, fn dep, {:ok, acc} ->
      case inject_one(acc, dep) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp inject_one(content, dep) do
    case Regex.run(~r/\A\{:([a-z][a-z0-9_]*),/, dep) do
      [_, name] -> inject_named(content, dep, name)
      _ -> {:error, {:not_a_dep, dep}}
    end
  end

  defp inject_named(content, dep, name) do
    cond do
      Regex.match?(~r/\{:#{name},/, content) ->
        {:ok, content}

      index = list_start(content, ~r/defp\s+deps\s+do\s*\n\s*\[/) ->
        {:ok, insert(content, index, "\n      #{dep},")}

      index = list_start(content, ~r/deps:\s*\[/) ->
        {:ok, insert(content, index, "#{dep}, ")}

      true ->
        {:error, :no_deps_list}
    end
  end

  @doc false
  # Public for tests: `content` with `prune_code_paths: false` first in
  # `project/0`'s keyword list, as Mix.install's project has it. Mix hands
  # it to every dependency's project (`Mix.Project.deps_config/1`), so no
  # dependency's compile prunes the code path, and a module an earlier
  # compile put there is found by a later one.
  @spec unpruned(String.t()) :: {:ok, String.t()} | {:error, term()}
  def unpruned(content) do
    case list_start(content, ~r/def\s+project\s*(?:,\s*do:\s*|do\s*)\[/) do
      nil -> {:error, :no_project_list}
      at -> {:ok, insert(content, at, "prune_code_paths: false, ")}
    end
  end

  defp list_start(content, regex) do
    case Regex.run(regex, content, return: :index) do
      [{start, len}] -> start + len
      _ -> nil
    end
  end

  defp insert(content, at, text) do
    {before, rest} = String.split_at(content, at)
    before <> text <> rest
  end

  defp fetched(:ok), do: :ok

  defp fetched({:error, why}),
    do: {:refuse, "the guarded packages cannot be added: deps.get failed (#{brief(why)})"}

  defp fetched(other), do: {:refuse, "the guarded packages cannot be added: #{brief(other)}"}

  # Every Hex release the first lock holds is locked the same in the
  # second: the guarded packages fit the closure as it is.
  defp same_lock(first, project_dir) do
    with {:ok, a} <- lock(first),
         {:ok, b} <- lock(project_dir) do
      a |> Enum.find(fn {app, release} -> Map.get(b, app) != release end) |> moved_release()
    end
  end

  defp moved_release(nil), do: :ok

  defp moved_release({app, _release}),
    do: {:refuse, "the guarded packages cannot be added: #{app} would be locked otherwise"}

  # sobelow_skip ["Traversal.FileModule"]
  defp lock(dir) do
    if File.exists?(Path.join(dir, "mix.lock")) do
      case DepsLock.hex_releases(dir) do
        {:ok, releases} -> {:ok, releases}
        _ -> {:refuse, "the guarded packages cannot be added: mix.lock cannot be read"}
      end
    else
      {:ok, %{}}
    end
  end

  # The first build's tracer options, with its own trace dir, judge mode
  # and the guarded packages' closure first.
  defp trace_opts(opts, env, trace_dir, present) do
    log = Keyword.get(opts, :log_file)

    [
      trace_dir: trace_dir,
      native: [],
      env: env,
      log_file: if(is_binary(log), do: log <> ".guarded"),
      timeout_ms: Keyword.get(opts, :timeout_ms, 30 * 60 * 1000),
      extra_env: Keyword.get(opts, :extra_env, []),
      run_started_at: Keyword.get(opts, :run_started_at),
      mode: :judge,
      first: present.first
    ] ++ Keyword.take(opts, [:reap, :cmd, :sweep, :window_sweep])
  end

  defp traced({:ok, 0}), do: :ok

  defp traced(other),
    do: {:refuse, "the build with the guarded packages did not finish: #{brief(other)}"}

  # Every guarded module of every entry in this world (`ids`) is in its
  # prober's ebin (an exact name's beam, or for a prefix at least one beam
  # under it), and none of an entry outside it: the world is the presence
  # vector it stands for.
  defp guarded_built(held, ids) do
    root = held.build |> Path.dirname()

    built =
      for {app, %{entries: entries}} <- held.waivers,
          entry <- Enum.filter(Guarded.entries(), &(&1.id in entries)),
          beams = beams(Path.join([root, app, "ebin"])),
          guard <- entry.guards,
          do: {entry.id, app, Enum.any?(beams, &Guarded.guarded?(&1, [guard]))}

    missing = for {id, app, false} <- built, id in ids, uniq: true, do: app
    extra = for {id, app, true} <- built, id not in ids, uniq: true, do: app

    cond do
      missing != [] ->
        {:refuse,
         "the guarded modules were not built with their package present: " <>
           Enum.join(missing, ", ")}

      extra != [] ->
        {:refuse,
         "the guarded modules were built without their package present: " <>
           Enum.join(extra, ", ")}

      true ->
        :ok
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp beams(ebin) do
    case File.ls(ebin) do
      {:ok, names} -> for n <- names, String.ends_with?(n, ".beam"), do: Path.rootname(n)
      _ -> []
    end
  end

  defp compared(:ok), do: :ok

  defp compared({:differs, why}),
    do: {:refuse, "the package builds otherwise with the guarded packages present: #{why}"}

  defp compared({:error, why}), do: {:refuse, "the builds cannot be compared: #{why}"}

  # sobelow_skip ["Traversal.FileModule"]
  defp remove(dir) when is_binary(dir) do
    File.rm_rf(dir)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Compares the first build's app dir (`first`, `<build path>/lib/<app>`)
  with the second's (see the moduledoc): `:ok`, `{:differs, why}` or
  `{:error, why}`. The beams are untrusted: they are read with a bounded
  chunk reader, and the decoded chunks with `NccWorker.Portability.Etf`,
  which creates no atoms.
  """
  @spec compare_app(String.t(), String.t()) :: :ok | {:differs, String.t()} | {:error, String.t()}
  def compare_app(first, second) do
    with :ok <- compare_ebin(Path.join(first, "ebin"), Path.join(second, "ebin")) do
      compare_tree(Path.join(first, "priv"), Path.join(second, "priv"), "priv")
    end
  rescue
    e -> {:error, "comparison failed: " <> Exception.message(e)}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp compare_ebin(a, b) do
    with {:ok, names_a} <- ls(a),
         {:ok, names_b} <- ls(b) do
      cond do
        names_a == [] -> {:error, "no ebin files"}
        names_a != names_b -> {:differs, "ebin holds other files"}
        true -> Enum.reduce_while(names_a, :ok, &ebin_file(&1, &2, a, b))
      end
    end
  end

  defp ebin_file(name, :ok, a, b) do
    with {:ok, x} <- read(Path.join(a, name)),
         {:ok, y} <- read(Path.join(b, name)) do
      result =
        cond do
          x == y -> :ok
          Path.extname(name) == ".beam" -> compare_beam(x, y)
          true -> {:differs, "differs"}
        end

      case result do
        :ok -> {:cont, :ok}
        {kind, why} -> {:halt, {kind, "ebin/#{name}: #{why}"}}
      end
    else
      {:error, why} -> {:halt, {:error, "ebin/#{name}: #{why}"}}
    end
  end

  @doc false
  # Public for tests: two beams' chunks, the same ids in the same order and
  # the same bytes, but `@decoded` chunks the same decoded terms.
  @spec compare_beam(binary(), binary()) :: :ok | {:differs, String.t()} | {:error, String.t()}
  def compare_beam(x, y) do
    with {:ok, a} <- chunks(x),
         {:ok, b} <- chunks(y) do
      if Enum.map(a, &elem(&1, 0)) == Enum.map(b, &elem(&1, 0)),
        do: a |> Enum.zip(b) |> Enum.find_value(:ok, &chunk_difference/1),
        else: {:differs, "other chunks"}
    end
  end

  defp chunk_difference({{_id, same}, {_id2, same}}), do: nil

  defp chunk_difference({{id, x}, {id, y}}) when id in @decoded do
    case {Etf.decode(x), Etf.decode(y)} do
      {{:ok, a}, {:ok, b}} ->
        if normal(a) == normal(b), do: nil, else: {:differs, "#{id} differs"}

      _ ->
        {:error, "#{id} cannot be decoded"}
    end
  end

  defp chunk_difference({{id, _x}, {id, _y}}), do: {:differs, "#{id} differs"}

  # A decoded term with every map's pairs in one order.
  defp normal({:map, pairs}),
    do: {:map, pairs |> Enum.map(fn {k, v} -> {normal(k), normal(v)} end) |> Enum.sort()}

  defp normal({:tuple, items}), do: {:tuple, Enum.map(items, &normal/1)}
  defp normal({:list, items, tail}), do: {:list, Enum.map(items, &normal/1), normal(tail)}
  defp normal({:export, m, f, a}), do: {:export, normal(m), normal(f), a}
  defp normal({:fun, m, free}), do: {:fun, normal(m), Enum.map(free, &normal/1)}
  defp normal(other), do: other

  # The chunks of an IFF beam container, in order, a gzipped one inflated
  # under a bound.
  defp chunks(<<31, 139, _::binary>> = gz) do
    case Etf.gunzip(gz, 64 * 1024 * 1024) do
      {:ok, <<"FOR1", _::binary>> = plain} -> chunks(plain)
      _ -> {:error, "unreadable beam"}
    end
  end

  defp chunks(<<"FOR1", size::32, "BEAM", body::binary>>) when size == byte_size(body) + 4,
    do: chunk_list(body, [])

  defp chunks(_binary), do: {:error, "unreadable beam"}

  defp chunk_list(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp chunk_list(<<id::binary-size(4), len::32, data::binary-size(len), rest::binary>>, acc) do
    pad = rem(4 - rem(len, 4), 4)

    case rest do
      <<_::binary-size(^pad), more::binary>> -> chunk_list(more, [{id, data} | acc])
      _ when rest == <<>> -> chunk_list(<<>>, [{id, data} | acc])
      _ -> {:error, "unreadable beam"}
    end
  end

  defp chunk_list(_truncated, _acc), do: {:error, "unreadable beam"}

  # The two `priv` trees, the top one followed when it is a link (Mix links
  # a build's `priv` to the dependency's source `priv`), every entry below
  # it read without following: the same relative paths, types, permission
  # bits, bytes and link targets. No `priv` on either side is the same.
  # sobelow_skip ["Traversal.FileModule"]
  defp compare_tree(a, b, label) do
    case {File.stat(a), File.stat(b)} do
      {{:error, :enoent}, {:error, :enoent}} ->
        :ok

      {{:ok, %File.Stat{type: :directory}}, {:ok, %File.Stat{type: :directory}}} ->
        same_tree(a, b, label)

      _ ->
        {:differs, "#{label} differs"}
    end
  end

  defp same_tree(a, b, label) do
    with {:ok, ta} <- tree(a),
         {:ok, tb} <- tree(b) do
      if ta == tb, do: :ok, else: {:differs, "#{label} differs"}
    end
  end

  # `%{relative path => {type, mode, bytes or link target}}`, bounded.
  # sobelow_skip ["Traversal.FileModule"]
  defp tree(root) do
    walk([""], root, %{}, 0)
  end

  defp walk([], _root, acc, _bytes), do: {:ok, acc}

  defp walk(_rels, _root, acc, _bytes) when map_size(acc) > @max_entries,
    do: {:error, "priv has too many entries"}

  defp walk(_rels, _root, _acc, bytes) when bytes > @max_file_bytes,
    do: {:error, "priv is too large"}

  # sobelow_skip ["Traversal.FileModule"]
  defp walk([rel | rest], root, acc, bytes) do
    path = if rel == "", do: root, else: Path.join(root, rel)

    case {rel, File.lstat(path)} do
      {"", _} ->
        walk(children(path, "") ++ rest, root, acc, bytes)

      {_, {:ok, %File.Stat{type: :directory, mode: mode}}} ->
        walk(children(path, rel) ++ rest, root, Map.put(acc, rel, {:directory, mode}), bytes)

      {_, {:ok, %File.Stat{type: :symlink}}} ->
        {:ok, target} = File.read_link(path)
        walk(rest, root, Map.put(acc, rel, {:symlink, target}), bytes)

      {_, {:ok, %File.Stat{type: :regular, mode: mode, size: size}}} ->
        {:ok, data} = read(path)
        walk(rest, root, Map.put(acc, rel, {:regular, mode, data}), bytes + size)

      {_, {:ok, %File.Stat{type: type}}} ->
        walk(rest, root, Map.put(acc, rel, {type}), bytes)

      {_, {:error, why}} ->
        {:error, "#{rel} cannot be read: #{inspect(why)}"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp children(path, rel) do
    case File.ls(path) do
      {:ok, names} ->
        names |> Enum.sort() |> Enum.map(&if(rel == "", do: &1, else: Path.join(rel, &1)))

      _ ->
        []
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> {:ok, Enum.sort(names)}
      {:error, why} -> {:error, "#{Path.basename(dir)} cannot be listed: #{inspect(why)}"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes <-
           File.stat(path),
         {:ok, data} <- File.read(path) do
      {:ok, data}
    else
      _ -> {:error, "#{Path.basename(path)} cannot be read"}
    end
  end

  # --- the verdict -------------------------------------------------------------

  defp pass(verdict, held, present, ms) do
    %{
      verdict
      | status: :pass,
        reason: nil,
        compile_env: held.compile_env
    }
    |> Map.put(:compile_inputs, held.compile_inputs)
    |> put_present(:built_priv, held.built_priv)
    |> put_present(:foreign_priv, held.foreign_priv)
    |> put_present(:foreign_priv_rule, held.foreign_priv_rule)
    |> Map.delete(:guarded)
    |> update_problems(&List.delete(&1, @hold_problem))
    |> put_stat(%{
      "result" => "same",
      "ms" => ms,
      "present" => present.first,
      "worlds" => present.worlds
    })
  end

  defp refuse(verdict, held, why, present, ms) do
    verdict
    |> Map.merge(%{status: :skip, reason: held.refusal, compile_env: nil, compile_inputs: nil})
    |> Map.delete(:guarded)
    |> ForeignPriv.unpass()
    |> update_problems(&(List.delete(&1, @hold_problem) ++ [String.slice(why, 0, 500)]))
    |> put_taint(held.waivers)
    |> put_stat(%{
      "result" => "refused",
      "why" => String.slice(why, 0, 500),
      "ms" => ms,
      "present" => present && present.first
    })
  end

  defp put_present(verdict, _key, nil), do: verdict
  defp put_present(verdict, key, value), do: Map.put(verdict, key, value)

  defp put_taint(%{observations: obs} = verdict, waivers) do
    taint =
      Enum.reduce(waivers, Map.get(obs, "taint") || %{}, fn {app, %{reasons: reasons}}, acc ->
        Map.put_new(acc, app, reasons |> Enum.sort() |> hd())
      end)

    %{verdict | observations: Map.put(obs, "taint", taint)}
  end

  defp put_stat(%{observations: obs} = verdict, value) do
    stats = Map.get(obs, "trace_stats") || %{}
    %{verdict | observations: Map.put(obs, "trace_stats", Map.put(stats, "guarded_proof", value))}
  end

  defp update_problems(%{observations: obs} = verdict, fun) do
    %{verdict | observations: Map.put(obs, "problems", fun.(Map.get(obs, "problems") || []))}
  end

  defp env_value(env, name) do
    case env |> Enum.reverse() |> List.keyfind(name, 0) do
      {_, value} when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp brief(term) when is_binary(term), do: String.slice(term, -300, 300)
  defp brief(term), do: inspect(term, limit: 8, printable_limit: 300)
end
