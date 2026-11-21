defmodule NccWorker.Portability.Relocate do
  @moduledoc """
  Relocatable builds (S4, `NCC_INPUT.judge.relocate`): the second build that
  lets a build whose beams bake the deps or build path pass, the path to be
  rewritten to the user's own at install (`Compatibility.Relocation`).

  R2 (`NccWorker.Portability.BuildRoot`) refuses a beam that holds the build
  root, and R3 every dependent of a dependency R2 refused. With `relocate:
  true` in `NccWorker.Portability.run/3`'s opts:

    * `hold/3`: a refused verdict that would pass if R2 had not refused some
      apps (the package itself, or closure dependencies whose only taint is
      their own R2 refusal) is held, when for each of those apps every root
      R2 searches but the project dir is absent from its beams (R2 on the
      other roots alone), and every occurrence of the build's deps path or
      build path in them sits where a rewrite reaches it
      (`Compatibility.Relocation.occurrences/2`). The modules holding one
      are that app's holders. A held verdict is the refusal it was, with
      `:relocate` holding what the pass would have said; a caller that
      judges a trace alone (`judge/5`) never publishes it;
    * `settle/6` copies the project to two extra roots and runs the traced
      judge compile of the package's closure again at each, the first
      build's tree snapshot passed on, with call patterns on the holders
      once each one's window has closed (`:ncc_tracer`'s `root_holder`
      channel). The second root (`Compatibility.Relocation.second_layout/2`)
      is under `/home/ncc-relocate`, in its `.cache/mix/installs`, under
      `/home/` but outside the container's `HOME`, which is one of R2's
      roots (the umbrella re-review's Q2); the third (`third_layout/2`) is
      under `/Users`. Both are per-run scratch dirs the portal binds there
      for a build that may relocate (`Portal.Builder`), and both run for
      every hold (the umbrella re-review's Q1). The three
      roots differ in length and depth, case, spaces, project dir name and
      the order of the deps and build paths, and hold between them the
      words user paths hold (a home's `.cache/mix/installs`, `Library`,
      `Projects`, `projects`, `src`, `code`, `app`, `nix/store`, a dot-dir,
      `@` and `~`). A later window's call into a holder, its read of a
      holder's `ebin`, or its read of a holder's md5, attributes or compile
      info (`module_info/0,1`, `__info__/1`) is a taint (`holder_calls`), a
      refusal in the package's own window;
    * each extra build must be held the same way, for the same apps, its
      pass the same `compile_env`, `compile_inputs` and `manager`, the first
      build's package dir the same before and after, and every closure
      app's source dir and build dir must list the same files, by relative
      path and type, as the first build's: a native build tool that split a
      path with a space and put its output elsewhere, exiting 0 all the
      same, refuses (the umbrella re-review's R2);
    * each held app's `ebin`, and the package's own whether it was held or
      not, must prove at every extra root (`Compatibility.Relocation.prove_ebin/4`):
      relocated to that root's paths, every beam is that build's chunk for
      chunk but metadata, and every other file the same. So a value the
      package's compile took from a held dependency through any channel
      (its md5, a path no holder pattern saw) refuses; a package that was
      not held may differ only where R2 already allows a path (a `keep`
      location, a line table's file name), and is served as it was built.

  Then the verdict is the pass it held, every beam of the package's own
  `ebin` compiled from its dir under the first deps path (its `CInf`
  source, `Relocation.compiled_in_problem/3`). It carries `relocation`: the
  first build's `deps` and `build` paths, the second and third builds'
  (`second`, `third`, from which the client takes the envelope of paths it
  relocates to) and, per beam of its `ebin` that needs a rewrite,
  `%{"path" => "ebin/<file>", "occurrences" => [...]}`. That is so both
  when the package itself was held and when only its dependencies were: a
  dependent's own beams often need no rewrite (`files` empty), but its
  pass rests on the same residual, so the portal stores, gates and revokes
  it as a relocated build and the client's envelope holds it.
  `trace_stats["relocate"]` says which (`"relocated"`, `"dependencies"`), or
  why it stayed refused (`"refused: <why>"`), and the verdict is then the
  first build's refusal, unchanged; `NccWorker.Portability.judge/5` writes
  `"on"` or `"off"` first, so every toolchain verdict says which way it was
  judged. Each extra root's run dir is removed either way. Never raises.

  What the roots cannot show, the residual: a compile-time test of the path
  against a constant that none of the three roots contains (a prefix such
  as `/opt/` or `/srv/`, a word no root holds), or any test that answers the
  same at all three roots and differently at the user's path. For a
  dependent that passed because a dependency was held, that path is the
  dependency's, and the test sits in the dependency's code or the
  dependent's. The client relocates only to paths inside the envelope the
  three roots span (their characters, between their lengths and depths),
  which bounds tests of length, depth and characters, not tests of which
  words a path holds. Today R2 refuses every build whose beams hold the
  path, and R3 every dependent of one, so this residual is new exposure that
  S4 brings, for relocated builds and such dependents only. `Dbgi` keeps
  the first build's paths: a tool that compiles a module again from its
  debug info (`:cover` on a dependency, the debugger) sees them, as it sees
  them in every served build.
  """

  alias Compatibility.Relocation
  alias NccWorker.Portability.{BuildRoot, Context}

  @baked "bakes the build path: "
  @max_beam_bytes 256 * 1024 * 1024
  @max_files 20_000

  @doc "`true` (a first build), `:second` (a relocation's second build) or `false`."
  @spec enabled(keyword()) :: true | :second | false
  def enabled(opts) do
    case Keyword.get(opts, :relocate) do
      true -> true
      :second -> :second
      _ -> false
    end
  end

  @doc """
  The build's slots, `%{"deps" => ..., "build" => ...}`: the dir the compile
  read the dependencies from and its build path (`build_path:`), both real
  paths that are their own spelling; `nil` otherwise, and then nothing is
  held.
  """
  @spec slots(Context.t(), keyword()) :: Relocation.slots() | nil
  def slots(ctx, opts) do
    deps = Context.deps_path(ctx)
    build = Keyword.get(opts, :build_path)

    if is_binary(deps) and is_binary(build) and Context.realpath(build) == build and
         Context.realpath(deps) == deps,
       do: %{"deps" => deps, "build" => build}
  end

  @doc """
  `verdict` held for a second build when `passing` (a function of the apps
  whose R2 refusal it lifts, returning `NccWorker.Portability`'s verdict
  without them) passes; otherwise `verdict` as it is (see the moduledoc).
  """
  @spec hold(map(), map(), (list() -> map())) :: map()
  def hold(%{status: :skip} = verdict, %{relocate: on, slots: %{} = slots} = facts, passing)
      when on in [true, :second] do
    with {:ok, held} <- candidates(facts, slots),
         apps = Map.keys(held),
         true <- apps != [],
         %{status: :pass, built_priv: []} = passed <- passing.(apps) |> second_refusal(on),
         false <- Map.has_key?(passed, :priv_repro) do
      Map.put(verdict, :relocate, %{
        passed: passed,
        package: facts.ctx.package,
        apps: Enum.sort(apps),
        holders: for({app, modules} <- held, module <- modules, do: {app, module}),
        ebins: Map.new([facts.ctx.package | apps], &{&1, Context.ebin(facts.ctx, &1)}),
        dirs: closure_dirs(facts.ctx),
        slots: slots,
        trees: facts.ctx.trees,
        build: package_build(facts.ctx)
      })
    else
      {:refused, reason} -> Map.put(verdict, :relocate_refused, reason)
      _ -> verdict
    end
  rescue
    _ -> verdict
  end

  def hold(verdict, _facts, _passing), do: verdict

  # In the second build, why the verdict without R2 still refused (a holder
  # called), for the first build to report.
  defp second_refusal(%{status: :skip, reason: reason}, :second), do: {:refused, reason}
  defp second_refusal(verdict, _on), do: verdict

  # Every closure app's source dir and build dir, which an extra build's own
  # must list the same files in (`same_trees/2`).
  defp closure_dirs(ctx) do
    for app <- Context.closure_of(ctx, ctx.package),
        Context.dep?(ctx, app),
        into: %{},
        do: {app, {ctx.deps[app].dest, ctx.deps[app].build}}
  end

  defp package_build(ctx),
    do: if(Context.dep?(ctx, ctx.package), do: ctx.deps[ctx.package].build)

  # `%{app => holder modules}` of every app whose only refusal is R2's baked
  # path; `:error` when one of them cannot be held.
  defp candidates(facts, slots) do
    refused =
      [{facts.ctx.package, facts.package_r2, nil, facts.package_rebar}] ++
        for {app, result} <- facts.deps, do: {app, result.r2, result.taint, result.rebar}

    refused
    |> Enum.filter(&baked?/1)
    |> Enum.reduce_while({:ok, %{}}, fn {app, _, _, _}, {:ok, acc} ->
      case holders(facts.ctx, app, slots) do
        {:ok, modules} -> {:cont, {:ok, Map.put(acc, app, modules)}}
        :error -> {:halt, :error}
      end
    end)
  end

  # R2 refused it for a baked path, and nothing else tainted it: a
  # dependency's taint is that same refusal, and no rebar3 rule refused.
  defp baked?({_app, {:refuse, @baked <> _ = reason}, taint, rebar}),
    do: taint in [nil, reason] and not match?({tag, _} when tag in [:refuse, :error], rebar)

  defp baked?(_result), do: false

  # The app's holder modules, the ones R2 refuses: R2 on every root but the
  # project dir finds nothing, and every beam's occurrences of the slots are
  # reachable. A module whose only path is in a shape R2 allows (a `keep`
  # or `file:` source path a macro hands its caller) is no holder: it is
  # what every dependency's beams may hand on today.
  # sobelow_skip ["Traversal.FileModule"]
  defp holders(ctx, app, slots) do
    closure_file? = &Context.closure_file?(ctx, &1)
    opts = [closure_dir?: &Context.closure_dir?(ctx, &1)]

    with ebin when is_binary(ebin) <- Context.ebin(ctx, app),
         {:ok, others} <- other_roots(ctx, slots),
         clean when clean == :ok or elem(clean, 0) == :observe <-
           BuildRoot.check(ebin, others, closure_file?, opts),
         {:ok, beams} <- File.ls(ebin),
         true <- Enum.all?(beams, &reachable?(ebin, &1, slots)),
         {:ok, [_ | _] = modules} <-
           BuildRoot.refusing_modules(ebin, Context.roots(ctx), closure_file?, opts) do
      {:ok, modules}
    else
      _ -> :error
    end
  end

  defp reachable?(ebin, name, slots) do
    Path.extname(name) != ".beam" or
      match?({:ok, _}, beam_occurrences(Path.join(ebin, name), slots))
  end

  # Every root R2 searches but the project dir. One that holds a slot (a
  # `HOME` above the project) cannot be told from it: nothing is held then.
  defp other_roots(ctx, slots) do
    project = ctx.project_dir

    others =
      Enum.reject(Context.roots(ctx), &(&1 == project or Context.realpath(&1) == project))

    if Enum.any?(others, fn root -> Enum.any?(Map.values(slots), &String.contains?(&1, root)) end),
       do: :error,
       else: {:ok, others}
  end

  defp beam_occurrences(path, slots) do
    with {:ok, bytes} <- read_file(path), do: Relocation.occurrences(bytes, slots)
  end

  @doc """
  Decides a verdict `hold/3` held by building the package again at another
  root (see the moduledoc); any other verdict is returned as it is. The
  second build's own verdict (`relocate: :second`) keeps its `:relocate`
  for the first build to read. `run` is `NccWorker.Portability.run/3`; `digest` hashes a
  build dir. `opts` are `run/3`'s, plus `relocate_root:` (tests).
  """
  @spec settle(map(), String.t(), String.t(), keyword(), fun(), fun()) :: map()
  def settle(%{relocate: held} = verdict, project_dir, package, opts, run, digest)
      when is_map(held) do
    case enabled(opts) do
      true ->
        verdict
        |> Map.drop([:relocate, :relocate_refused])
        |> reproduce(held, project_dir, package, opts, run, digest)

      # The second build's own hold is what the first build's decide/5 reads.
      :second ->
        verdict

      false ->
        Map.drop(verdict, [:relocate, :relocate_refused])
    end
  rescue
    e ->
      verdict
      |> Map.drop([:relocate, :relocate_refused])
      |> refused("second build failed: " <> Exception.message(e))
  end

  def settle(verdict, _project_dir, _package, opts, _run, _digest) do
    if enabled(opts) == :second, do: verdict, else: Map.delete(verdict, :relocate_refused)
  end

  # The extra roots (`Compatibility.Relocation.second_layout/2` and
  # `third_layout/2`): under `/home/ncc-relocate` and `/Users` in the
  # container (`Relocation.bases/0`), under `relocate_root:` in tests. Both
  # run for every hold, a dependent's whose own beams hold no path too (the
  # umbrella re-review's Q1): a held dependency can bake a test of its path
  # against a constant in a module that holds no path, which a dependent
  # then reads at compile time. Each root's run dir is the only dir this
  # function removes.
  # sobelow_skip ["Traversal.FileModule"]
  defp reproduce(verdict, held, project_dir, package, opts, run, digest) do
    n = System.unique_integer([:positive])
    {home, users, scratch} = bases(opts)
    second = Relocation.second_layout(home, n)
    third = Relocation.third_layout(users, n)
    roots = [second, third]

    job = %{
      held: held,
      project_dir: project_dir,
      package: package,
      opts: opts,
      run: run,
      digest: digest
    }

    Enum.reduce_while(roots, {:ok, %{}}, fn layout, {:ok, acc} ->
      case extra(job, layout, scratch) do
        {:ok, slots, relocated} -> {:cont, {:ok, Map.put(acc, layout, {slots, relocated})}}
        {:refuse, why} -> {:halt, {:refuse, why}}
      end
    end)
    |> case do
      {:ok, done} ->
        case pass(held, done[second], done[third]) do
          {:refuse, why} -> refused(verdict, why)
          passed -> passed
        end

      {:refuse, why} ->
        refused(verdict, why)
    end
  end

  defp bases(opts) do
    %{second: home, third: users} = Relocation.bases()

    case Keyword.get(opts, :relocate_root) do
      nil ->
        {home, users, System.tmp_dir!()}

      root ->
        root = Context.realpath(root)

        {Path.join(root, String.trim_leading(home, "/")),
         Path.join(root, String.trim_leading(users, "/")), root}
    end
  end

  # One extra build at `layout`: `{:ok, slots, relocated}` (each proved
  # app's beams to rewrite) or `{:refuse, why}`. Its trace dir and log are
  # under the scratch base, apart from the layout.
  # sobelow_skip ["Traversal.FileModule"]
  defp extra(job, layout, scratch) do
    %{held: held, project_dir: project_dir, package: package, opts: opts} = job
    run_dir = run_dir(layout)
    trace = Path.join(scratch, "ncc-relocate-trace-#{System.unique_integer([:positive])}")
    slots = Map.take(layout, ["deps", "build"])

    try do
      with :ok <- copy_project(project_dir, layout["project"], held.slots, slots),
           slots = Map.new(slots, fn {k, v} -> {k, Context.realpath(v)} end),
           {:ok, _} = before <- job.digest.(held.build) do
        second = job.run.(layout["project"], package, second_opts(opts, trace, slots, held))
        later = job.digest.(held.build)
        decide(held, second, slots, {before, later})
      else
        {:error, why} -> {:refuse, "second build: #{inspect(why)}"}
        other -> {:refuse, "second build: #{inspect(other, limit: 5)}"}
      end
    rescue
      e -> {:refuse, "second build failed: " <> Exception.message(e)}
    after
      File.rm_rf(run_dir)
      File.rm_rf(trace)
    end
  end

  # The run-unique top dir of a layout: the component that names the run
  # token, and everything under it.
  defp run_dir(%{"project" => project}) do
    project
    |> Path.split()
    |> Enum.reduce_while([], fn part, acc ->
      acc = acc ++ [part]
      if part =~ ~r/\A(ncc-relocate-|Ncc-Relocate )[0-9]+\z/, do: {:halt, acc}, else: {:cont, acc}
    end)
    |> Path.join()
  end

  # The project's own files, but the first build's deps and build dirs, and
  # its dependencies' sources to the second build's deps dir.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_project(project_dir, proj, from, to) do
    File.mkdir_p!(proj)

    for name <- File.ls!(project_dir),
        source = Path.join(project_dir, name),
        not Enum.any?(Map.values(from), &under?(&1, source)) do
      File.cp_r!(source, Path.join(proj, name))
    end

    File.mkdir_p!(Path.dirname(to["deps"]))
    File.cp_r!(from["deps"], to["deps"])
    File.mkdir_p!(to["build"])
    :ok
  end

  defp under?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  # The first build's opts with the second build's deps and build paths in
  # its env, its own trace dir and log, judge mode, the first build's tree
  # snapshot (one taken now would be after the first compile, which wrote
  # leex and yecc output into the sources), no second build of its own and
  # the holders patterned.
  defp second_opts(opts, trace, slots, held) do
    opts
    |> Keyword.drop([:trees, :trace_dir, :log_file, :mode, :env, :extra_env, :relocate])
    |> Keyword.merge(
      env: paths(Keyword.fetch!(opts, :env), slots, true),
      extra_env: paths(Keyword.get(opts, :extra_env, []), slots, false),
      mode: :judge,
      trees: held.trees,
      trace_dir: Path.join(trace, "trace"),
      log_file: Path.join(trace, "compile.log"),
      priv_repro: false,
      relocate: :second,
      holders: held.holders
    )
  end

  defp paths(env, slots, always?) do
    Enum.reduce([{"MIX_DEPS_PATH", "deps"}, {"MIX_BUILD_PATH", "build"}], env, fn {var, slot},
                                                                                  env ->
      if always? or List.keymember?(env, var, 0),
        do: List.keystore(env, var, 0, {var, slots[slot]}),
        else: env
    end)
  end

  defp decide(held, second, slots, digests) do
    case second_problem(held, second, digests) do
      nil -> prove(held, second.relocate, slots)
      why -> {:refuse, why}
    end
  end

  defp second_problem(held, second, digests) do
    cond do
      get_in(second, [:observations, "trace_stats", "judge_compile"]) != "finished" ->
        "the second build did not finish"

      not is_map(Map.get(second, :relocate)) ->
        "the second build refused (#{Map.get(second, :relocate_refused) || second.reason || "pass"})"

      true ->
        held_problem(held, second.relocate, digests)
    end
  end

  defp held_problem(held, other, digests) do
    cond do
      other.apps != held.apps -> "the second build held other apps"
      other.passed.status != :pass -> "the second build's pass differs"
      facts(other.passed) != facts(held.passed) -> "the second build's pass differs"
      not same_digest?(digests) -> "the first build changed while the second ran"
      why = same_trees(held.dirs, other.dirs) -> why
      true -> nil
    end
  end

  defp facts(passed), do: Map.take(passed, [:compile_env, :compile_inputs, :manager])

  defp same_digest?({{:ok, digest}, {:ok, digest}}), do: true
  defp same_digest?(_digests), do: false

  # Every held app's ebin, and the package's own whether it was held or
  # not: a value its compile derived from a held dependency (the holder's
  # md5, a path through a channel no holder pattern sees) differs at the
  # two roots, and a package that was not held may differ only where R2
  # already allows a path (a `keep` location, a line table's file name).
  defp prove(held, other, slots) do
    Enum.uniq(held.apps ++ [held.package])
    |> Enum.reduce_while({:ok, %{}}, fn app, {:ok, acc} ->
      with {:ok, a} <- read_ebin(held.ebins[app]),
           {:ok, b} <- read_ebin(other.ebins[app]),
           {:ok, relocated} <- Relocation.prove_ebin(a, held.slots, b, slots) do
        {:cont, {:ok, Map.put(acc, app, relocated)}}
      else
        {:refuse, why} -> {:halt, {:refuse, "#{app}: #{why}"}}
        _ -> {:halt, {:refuse, "#{app}: unreadable ebin"}}
      end
    end)
    |> case do
      {:ok, relocated} -> {:ok, slots, relocated}
      {:refuse, why} -> {:refuse, why}
    end
  end

  # The pass the hold kept, with its record: the first build's paths, the
  # other two roots' and the package's own beams to rewrite, the same at the
  # second root and the third, which they always are (both derive from the
  # first build's beams and paths). A package held for its own R2 refusal
  # is `"relocated"` and must hold a path. A dependent that passed because
  # a dependency was held (`"dependencies"`) carries the same record, with
  # the occurrences of the paths R2 allows in its beams (a `keep` location's
  # file name), often none (the umbrella re-review's Q1): it rests on the
  # same residual, so it is stored, gated and revoked as a relocated build,
  # and the client's envelope holds it. Every beam of the package's own ebin
  # must have been compiled from its dir under the first build's deps path
  # (`Relocation.compiled_in_problem/3`), and the record must be one the
  # portal and the client take (`Relocation.record_problem/3`, the closure's
  # apps the only ones a build path may be followed by).
  defp pass(held, {second, at_second}, {third, at_third}) do
    own = Map.get(at_second, held.package, %{})
    relocated? = held.package in held.apps

    record = %{
      "deps" => held.slots["deps"],
      "build" => held.slots["build"],
      "second" => second,
      "third" => third,
      "files" =>
        for {name, occs} <- Enum.sort(own) do
          %{"path" => "ebin/" <> name, "occurrences" => occs}
        end
    }

    with {:ok, ebin} <- own_ebin(held),
         nil <- pass_problem(held, own, at_third, relocated?, ebin),
         nil <-
           Relocation.record_problem(
             record,
             Enum.map(Map.keys(ebin), &("ebin/" <> &1)),
             Enum.uniq([held.package | Map.keys(held.dirs)])
           ) do
      held.passed
      |> Map.put(:relocation, record)
      |> put_stat("relocate", if(relocated?, do: "relocated", else: "dependencies"))
    else
      {:refuse, why} -> {:refuse, why}
      why when is_binary(why) -> {:refuse, why}
      _ -> {:refuse, "#{held.package}: unreadable ebin"}
    end
  end

  defp own_ebin(held) do
    case read_ebin(held.ebins[held.package]) do
      {:ok, ebin} -> {:ok, ebin}
      _ -> {:refuse, "#{held.package}: unreadable ebin"}
    end
  end

  defp pass_problem(held, own, at_third, relocated?, ebin) do
    cond do
      relocated? and map_size(own) == 0 ->
        "the package holds no path"

      own != Map.get(at_third, held.package, %{}) ->
        "the second and third roots recorded other occurrences"

      true ->
        Relocation.compiled_in_problem(ebin, held.slots["deps"], held.package)
    end
  end

  # The umbrella re-review's R2: a dependency's own build tool (GNU make,
  # given a path with a space) can write its output somewhere else and still
  # exit 0. Every closure app's source dir and build dir must list the same
  # files, by relative path and type, after an extra build as after the
  # first; a NIF the extra build did not put in place, or a stray file it
  # put in the wrong place, refuses.
  defp same_trees(first, other) do
    Enum.find_value(Enum.sort(first), fn {app, {dest, build}} ->
      case Map.get(other, app) do
        {other_dest, other_build} ->
          tree_problem(app, "sources", dest, other_dest) ||
            tree_problem(app, "build", build, other_build)

        nil ->
          "the second build has no #{app}"
      end
    end)
  end

  defp tree_problem(app, what, a, b) do
    case {listing(a), listing(b)} do
      {{:ok, same}, {:ok, same}} -> nil
      {{:ok, _}, {:ok, _}} -> "#{app}'s #{what} differ in the second build"
      _ -> "#{app}'s #{what} could not be listed"
    end
  end

  @max_listing 100_000

  # `rel => type` of everything under `dir`, links not followed; a missing
  # dir lists nothing.
  # sobelow_skip ["Traversal.FileModule"]
  defp listing(nil), do: {:ok, %{}}

  defp listing(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} -> walk(dir, "", %{})
      {:error, :enoent} -> {:ok, %{}}
      _ -> :error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp walk(dir, rel, acc) do
    case File.ls(Path.join(dir, rel)) do
      {:ok, names} ->
        Enum.reduce_while(Enum.sort(names), {:ok, acc}, &walk_entry(dir, rel, &1, &2))

      _ ->
        :error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp walk_entry(dir, rel, name, {:ok, acc}) do
    entry = if rel == "", do: name, else: Path.join(rel, name)

    case File.lstat(Path.join(dir, entry)) do
      {:ok, _} when map_size(acc) >= @max_listing ->
        {:halt, :error}

      {:ok, %File.Stat{type: :directory}} ->
        walked(walk(dir, entry, Map.put(acc, entry, :directory)))

      {:ok, %File.Stat{type: type}} ->
        {:cont, {:ok, Map.put(acc, entry, type)}}

      _ ->
        {:halt, :error}
    end
  end

  defp walked({:ok, _} = ok), do: {:cont, ok}
  defp walked(:error), do: {:halt, :error}

  # sobelow_skip ["Traversal.FileModule"]
  defp read_ebin(ebin) when is_binary(ebin) do
    with {:ok, names} <- File.ls(ebin),
         true <- length(names) <= @max_files do
      Enum.reduce_while(Enum.sort(names), {:ok, %{}}, &read_named(ebin, &1, &2))
    else
      _ -> :error
    end
  end

  defp read_ebin(_ebin), do: :error

  defp read_named(ebin, name, {:ok, acc}) do
    case read_file(Path.join(ebin, name)) do
      {:ok, bytes} -> {:cont, {:ok, Map.put(acc, name, bytes)}}
      :error -> {:halt, :error}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_file(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_beam_bytes <-
           File.lstat(path),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  # The first build's refusal, as it was, with why it stayed one.
  defp refused(verdict, why),
    do: put_stat(verdict, "relocate", "refused: " <> String.slice(why, 0, 160))

  defp put_stat(%{observations: obs} = verdict, key, value) do
    stats = Map.get(obs, "trace_stats") || %{}
    %{verdict | observations: Map.put(obs, "trace_stats", Map.put(stats, key, value))}
  end

  defp put_stat(verdict, _key, _value), do: verdict
end
