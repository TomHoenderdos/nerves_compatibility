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
    * `settle/6` copies the project to a fresh dir under the system temp dir,
      `<root>/second/proj`, its dependencies' sources to `vendored` and its
      build path at `out/host` there: other names and other lengths than the
      first build's `deps` and `_build/host`, so a path the compile derived
      from the project dir rather than from Mix's deps or build path differs
      from its rewrite. It runs the traced judge compile of the package's
      closure again there, the first build's tree snapshot passed on, with
      call patterns on the holders once each one's window has closed
      (`:ncc_tracer`'s `root_holder` channel). A later window's call into a
      holder, or read of a holder's `ebin`, is a taint (`holder_calls`), a
      refusal in the package's own window;
    * the second verdict must be held the same way, for the same apps, its
      pass the same `compile_env`, `compile_inputs` and `manager`, and the
      first build's package dir the same before and after;
    * each held app's `ebin` must prove (`Compatibility.Relocation.prove_ebin/4`):
      relocated to the second build's paths, every beam is the second
      build's chunk for chunk but metadata, and every other file the same.

  Then the verdict is the pass it held. When the package itself was held it
  carries `relocation`: the first build's `deps` and `build` paths and, per
  beam of its `ebin` that needs a rewrite, `%{"path" => "ebin/<file>",
  "occurrences" => [...]}`. A pass that only needed its dependencies held
  carries none: its own beams hold no path, and its compile never called a
  holder. `trace_stats["relocate"]` says which (`"relocated"`,
  `"dependencies"`), or why it stayed refused (`"refused: <why>"`), and the
  verdict is then the first build's refusal, unchanged. The second build's
  dir is removed either way. Never raises.

  What two builds cannot show: a value the compile derived from the path
  that is the same at both roots (its length compared with a constant) and
  holds no path. R2 cannot see one either, so a build that bakes one
  passes today with or without this.
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
        ebins: Map.new(apps, &{&1, Context.ebin(facts.ctx, &1)}),
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

  # The app's holder modules: R2 on every root but the project dir finds
  # nothing, and every beam's occurrences of the slots are reachable.
  # sobelow_skip ["Traversal.FileModule"]
  defp holders(ctx, app, slots) do
    with ebin when is_binary(ebin) <- Context.ebin(ctx, app),
         {:ok, others} <- other_roots(ctx, slots),
         clean when clean == :ok or elem(clean, 0) == :observe <-
           BuildRoot.check(ebin, others, &Context.closure_file?(ctx, &1),
             closure_dir?: &Context.closure_dir?(ctx, &1)
           ),
         {:ok, beams} <- File.ls(ebin) do
      beams
      |> Enum.filter(&(Path.extname(&1) == ".beam"))
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
        case beam_occurrences(Path.join(ebin, name), slots) do
          {:ok, []} -> {:cont, {:ok, acc}}
          {:ok, _} -> {:cont, {:ok, [Path.basename(name, ".beam") | acc]}}
          _ -> {:halt, :error}
        end
      end)
      |> then(fn
        {:ok, [_ | _] = modules} -> {:ok, Enum.reverse(modules)}
        _ -> :error
      end)
    else
      _ -> :error
    end
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

  # sobelow_skip ["Traversal.FileModule"]
  defp beam_occurrences(path, slots) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_beam_bytes <-
           File.lstat(path),
         {:ok, bytes} <- File.read(path) do
      Relocation.occurrences(bytes, slots)
    else
      _ -> :error
    end
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

  # `root` is a fresh directory this function names under the temp dir, and
  # the only one it removes.
  # sobelow_skip ["Traversal.FileModule"]
  defp reproduce(verdict, held, project_dir, package, opts, run, digest) do
    base = opts |> Keyword.get_lazy(:relocate_root, &System.tmp_dir!/0) |> Context.realpath()
    root = Path.join(base, "ncc-relocate-#{System.unique_integer([:positive])}")
    proj = Path.join(root, "second/proj")
    slots = %{"deps" => Path.join(proj, "vendored"), "build" => Path.join(proj, "out/host")}

    try do
      with :ok <- copy_project(project_dir, proj, held.slots, slots),
           slots = Map.new(slots, fn {k, v} -> {k, Context.realpath(v)} end),
           {:ok, _} = before <- digest.(held.build) do
        second = run.(proj, package, second_opts(opts, root, slots, held))
        later = digest.(held.build)
        decide(verdict, held, second, slots, {before, later})
      else
        {:error, why} -> refused(verdict, "second build: #{inspect(why)}")
        other -> refused(verdict, "second build: #{inspect(other, limit: 5)}")
      end
    after
      File.rm_rf(root)
    end
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
  defp second_opts(opts, root, slots, held) do
    opts
    |> Keyword.drop([:trees, :trace_dir, :log_file, :mode, :env, :extra_env, :relocate])
    |> Keyword.merge(
      env: paths(Keyword.fetch!(opts, :env), slots, true),
      extra_env: paths(Keyword.get(opts, :extra_env, []), slots, false),
      mode: :judge,
      trees: held.trees,
      trace_dir: Path.join(root, "trace"),
      log_file: Path.join(root, "compile.log"),
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

  defp decide(verdict, held, second, slots, digests) do
    other = Map.get(second, :relocate)

    cond do
      get_in(second, [:observations, "trace_stats", "judge_compile"]) != "finished" ->
        refused(verdict, "the second build did not finish")

      not is_map(other) ->
        why = Map.get(second, :relocate_refused) || second.reason || "pass"
        refused(verdict, "the second build refused (#{why})")

      other.apps != held.apps ->
        refused(verdict, "the second build held other apps")

      other.passed.status != :pass or facts(other.passed) != facts(held.passed) ->
        refused(verdict, "the second build's pass differs")

      not same_digest?(digests) ->
        refused(verdict, "the first build changed while the second ran")

      true ->
        prove(verdict, held, other, slots)
    end
  end

  defp facts(passed), do: Map.take(passed, [:compile_env, :compile_inputs, :manager])

  defp same_digest?({{:ok, digest}, {:ok, digest}}), do: true
  defp same_digest?(_digests), do: false

  defp prove(verdict, held, other, slots) do
    Enum.reduce_while(held.apps, {:ok, %{}}, fn app, {:ok, acc} ->
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
      {:ok, relocated} -> pass(held, relocated[held.package])
      {:refuse, why} -> refused(verdict, why)
    end
  end

  defp pass(held, own) when is_map(own) and map_size(own) > 0 do
    record = %{
      "deps" => held.slots["deps"],
      "build" => held.slots["build"],
      "files" =>
        for {name, occs} <- Enum.sort(own) do
          %{"path" => "ebin/" <> name, "occurrences" => occs}
        end
    }

    held.passed |> Map.put(:relocation, record) |> put_stat("relocate", "relocated")
  end

  defp pass(held, _own), do: put_stat(held.passed, "relocate", "dependencies")

  # sobelow_skip ["Traversal.FileModule"]
  defp read_ebin(ebin) when is_binary(ebin) do
    with {:ok, names} <- File.ls(ebin),
         true <- length(names) <= @max_files do
      Enum.reduce_while(Enum.sort(names), {:ok, %{}}, fn name, {:ok, acc} ->
        path = Path.join(ebin, name)

        with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_beam_bytes <-
               File.lstat(path),
             {:ok, bytes} <- File.read(path) do
          {:cont, {:ok, Map.put(acc, name, bytes)}}
        else
          _ -> {:halt, :error}
        end
      end)
    else
      _ -> :error
    end
  end

  defp read_ebin(_ebin), do: :error

  # The first build's refusal, as it was, with why it stayed one.
  defp refused(verdict, why),
    do: put_stat(verdict, "relocate", "refused: " <> String.slice(why, 0, 160))

  defp put_stat(%{observations: obs} = verdict, key, value) do
    stats = Map.get(obs, "trace_stats") || %{}
    %{verdict | observations: Map.put(obs, "trace_stats", Map.put(stats, key, value))}
  end

  defp put_stat(verdict, _key, _value), do: verdict
end
