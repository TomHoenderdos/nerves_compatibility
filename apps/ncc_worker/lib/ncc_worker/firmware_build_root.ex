defmodule NccWorker.FirmwareBuildRoot do
  @moduledoc """
  The baked build path rule (R2, `NccWorker.Portability.BuildRoot`) on the
  files a firmware target publishes, the same rule a toolchain or
  `pure_elixir` build's own beams are judged by
  (`BuildRoot.program_source_paths/4`).

  A firmware build compiles the package into `_build/<target>/lib/<package>`
  from `deps_<target>/<package>` under the run's project dir. A beam that
  keeps one of those paths (`__DIR__`, a compile-time `:code.priv_dir/1`, a
  `Path.expand(.., __DIR__)` its code reads at runtime) points at a tree that
  exists only on the builder. The roots are the project dir (so
  `deps_<target>` and `_build/<target>`), this VM's OTP root and Elixir
  install, `HOME`, `MIX_HOME`, the target's `HEX_HOME` and the Nerves
  artifact and download dirs (`NERVES_ARTIFACTS_DIR`, `NERVES_DL_DIR`):
  the firmware build's compile ran with the same ones.

  As on the host, a closure source path is a regular file under some
  dependency's dir in `deps_<target>` (outside its `priv/` and `test/`),
  and a template root a directory there (`closure_dir?:`). With no trace,
  the closure is the target's whole deps dir. So, in order:

    * no root in the beams, or only in the metadata shapes: published;
    * a bare closure source path (Ecto's query `file:`, a log line):
      published, observed (`build_root_source_path`), unless the module that
      holds it runs programs or the package runs a shell;
    * anything else (a directory, a `_build` path, a root in an atom, a
      `.app`), or a build R2 cannot read: withheld.

  Withheld means the target's own `beam_scan` loses its
  `footprint.file_manifest`, so nothing is archived or published for it, and
  a published variant (`NccWorker.OptionalDepsTargets`) that is withheld is
  dropped. Statuses, firmware images and logs never change. Every judged
  target gets `build_root` (`t:outcome/0`).
  """

  alias NccWorker.{BeamScan, OptionalDepsTargets}
  alias NccWorker.Portability.{BuildRoot, Context}

  @max_observations 50

  @typedoc """
  What the rule said about a target's own build: `status` "pass" (published)
  or "skipped" (withheld), the refusal or could-not-judge `reason`, the
  observations (at most #{@max_observations}), and, when a variant was
  judged, `variants` by name with its own status and reason.
  """
  @type outcome :: %{
          required(:status) => String.t(),
          required(:reason) => String.t() | nil,
          required(:observations) => [map()],
          optional(:variants) => %{String.t() => %{status: String.t(), reason: String.t() | nil}}
        }

  @type verdict ::
          :ok
          | {:observe, [BuildRoot.observation()]}
          | {:refuse, String.t()}
          | {:error, String.t()}

  @doc """
  R2 on one compiled application dir (`app_dir`, holding `ebin`) of a
  firmware build of `target` under `project_dir`. Options: `start:`, the
  roots as `Context.build_roots/2` takes them (default: this VM's and
  `env`'s), `env:`, the target's build env (`[{name, value}]`), for its
  `HEX_HOME`, and `extra_roots:` (default: the Nerves dirs).
  """
  @spec judge(String.t(), String.t(), String.t(), keyword()) :: verdict()
  def judge(app_dir, project_dir, target, opts \\ []) do
    deps = Context.realpath(Path.join(project_dir, "deps_#{target}"))
    start = Keyword.get_lazy(opts, :start, fn -> start(Keyword.get(opts, :env, [])) end)
    extra = Keyword.get_lazy(opts, :extra_roots, &nerves_roots/0)

    roots =
      [{project_dir, start} | Enum.map(extra, &{&1, %{}})]
      |> Enum.flat_map(fn {dir, start} -> Context.build_roots(dir, start) end)
      |> Enum.uniq()

    BuildRoot.program_source_paths(
      Path.join(app_dir, "ebin"),
      roots,
      &dep_file?(deps, &1),
      closure_dir?: &dep_dir?(deps, &1)
    )
  rescue
    error -> {:error, "firmware R2: " <> Exception.message(error)}
  end

  @doc """
  Judges every passing target of `systems` that publishes files, and its
  published variants, and withholds what the rule refuses. `targets` maps a
  system's name to `{target, env}`; a system it does not name is left as it
  is. Returns the systems and one line per withheld build, for the run's
  log. `judge` (default `judge/4`) is for tests.
  """
  @spec gate(%{String.t() => map()}, map(), keyword()) :: {%{String.t() => map()}, [String.t()]}
  def gate(systems, %{project_dir: project_dir, package: package, targets: targets}, opts \\ []) do
    judge = Keyword.get(opts, :judge, &judge/4)

    Enum.reduce(systems, {systems, []}, fn {name, result}, {acc, lines} ->
      case {judged?(result), Map.fetch(targets, name)} do
        {true, {:ok, {target, env}}} ->
          ctx = %{project_dir: project_dir, package: package, target: target, env: env}
          {result, new_lines} = gate_system(name, result, ctx, judge)
          {Map.put(acc, name, result), lines ++ new_lines}

        _ ->
          {acc, lines}
      end
    end)
  end

  defp judged?(result) do
    pass?(result[:status]) and (manifest?(result[:beam_scan]) or variants(result) != [])
  end

  defp pass?(status), do: status in [:pass, "pass"]

  defp manifest?(%{"footprint" => %{"file_manifest" => %{}}}), do: true
  defp manifest?(_scan), do: false

  defp variants(result), do: List.wrap(result[:published_variants])

  defp gate_system(name, result, ctx, judge) do
    build_path = Path.join([ctx.project_dir, "_build", ctx.target])
    opts = [env: ctx.env]

    {result, own_lines} =
      if manifest?(result.beam_scan) do
        verdict =
          case BeamScan.package_dir(build_path, ctx.package) do
            {:ok, dir} -> judge.(dir, ctx.project_dir, ctx.target, opts)
            {:error, why} -> {:error, "no build of #{ctx.package}: #{inspect(why)}"}
          end

        apply_own(name, result, verdict)
      else
        {result, []}
      end

    {kept, judged, variant_lines} =
      Enum.reduce(variants(result), {[], %{}, []}, fn variant, {kept, judged, lines} ->
        label = to_string(variant[:variant] || variant["variant"])

        case variant_verdict(
               variant,
               variant_dir(build_path, ctx.package, label),
               ctx,
               judge,
               opts
             ) do
          :keep ->
            {kept ++ [variant], judged, lines}

          {:publish, _verdict} ->
            {kept ++ [variant], Map.put(judged, label, record("pass", nil)), lines}

          {:withhold, reason} ->
            line = "Files of #{name} (#{label}) not published: #{reason}"
            {kept, Map.put(judged, label, record("skipped", reason)), lines ++ [line]}
        end
      end)

    result =
      result
      |> put_variants(kept)
      |> put_variant_records(judged)

    {result, own_lines ++ variant_lines}
  end

  # Each variant from its own `.<package>.<variant>` dir, and only a
  # variant this image publishes: any other name is never a path.
  @variants ["without" | Compatibility.Worlds.firmware_variants()]

  defp variant_dir(build_path, package, label) when label in @variants,
    do: Path.join([build_path, "lib", OptionalDepsTargets.variant_dir(package, label)])

  defp variant_dir(_build_path, _package, _label), do: nil

  defp variant_verdict(_variant, nil, _ctx, _judge, _opts),
    do: {:withhold, "portability could not be judged (unknown variant)"}

  defp variant_verdict(variant, dir, ctx, judge, opts) do
    if manifest?(variant[:beam_scan] || variant["beam_scan"]) do
      case decide(judge.(dir, ctx.project_dir, ctx.target, opts)) do
        {:publish, _} = publish -> publish
        {:withhold, reason, _observations} -> {:withhold, reason}
      end
    else
      :keep
    end
  end

  defp apply_own(name, result, verdict) do
    case decide(verdict) do
      {:publish, observations} ->
        {Map.put(result, :build_root, %{record("pass", nil) | observations: observations}), []}

      {:withhold, reason, observations} ->
        footprint = Map.delete(result.beam_scan["footprint"], "file_manifest")

        result =
          result
          |> Map.put(:beam_scan, Map.put(result.beam_scan, "footprint", footprint))
          |> Map.put(:build_root, %{record("skipped", reason) | observations: observations})

        {result, ["Files of #{name} not published: #{reason}"]}
    end
  end

  defp decide(:ok), do: {:publish, []}
  defp decide({:observe, list}) when is_list(list), do: {:publish, observations(list)}
  defp decide({:refuse, reason}) when is_binary(reason), do: {:withhold, reason, []}

  defp decide({:error, why}) when is_binary(why),
    do: {:withhold, "portability could not be judged (#{why})", []}

  defp decide(other),
    do: {:withhold, "portability could not be judged (#{inspect(other, limit: 5)})", []}

  defp observations(list) do
    list
    |> Enum.flat_map(fn
      {:observe, rule, path} -> [%{"rule" => rule, "path" => path}]
      _other -> []
    end)
    |> Enum.take(@max_observations)
  end

  defp record(status, reason), do: %{status: status, reason: reason, observations: []}

  defp put_variants(result, kept) do
    cond do
      not Map.has_key?(result, :published_variants) -> result
      kept == [] -> Map.delete(result, :published_variants)
      true -> Map.put(result, :published_variants, kept)
    end
  end

  defp put_variant_records(result, judged) when judged == %{}, do: result

  defp put_variant_records(result, judged) do
    variants = Map.new(judged, fn {label, rec} -> {label, Map.take(rec, [:status, :reason])} end)

    Map.update(
      result,
      :build_root,
      %{status: "pass", reason: nil, observations: [], variants: variants},
      &Map.put(&1, :variants, variants)
    )
  end

  # The roots the firmware build's compile had: this VM's OTP and Elixir
  # (the same image), `HOME`, `MIX_HOME` and the target's `HEX_HOME`.
  defp start(env) do
    home = System.get_env("HOME")

    %{
      "otp_root" => to_string(:code.root_dir()),
      "elixir_root" => elixir_root(),
      "home" => home,
      "mix_home" => System.get_env("MIX_HOME") || (home && Path.join(home, ".mix")),
      "hex_home" => env_value(env, "HEX_HOME") || System.get_env("HEX_HOME")
    }
  end

  defp elixir_root do
    case :code.lib_dir(:elixir) do
      dir when is_list(dir) -> dir |> to_string() |> Path.dirname()
      _ -> nil
    end
  end

  defp env_value(env, name) do
    Enum.find_value(env, fn
      {^name, value} when is_binary(value) and value != "" -> value
      _ -> nil
    end)
  end

  defp nerves_roots do
    ~w(NERVES_ARTIFACTS_DIR NERVES_DL_DIR)
    |> Enum.map(&System.get_env/1)
    |> Enum.filter(&(is_binary(&1) and Path.type(&1) == :absolute))
  end

  # A regular file inside some dependency's dir of `deps_<target>`, by its
  # real path; `BuildRoot` also checks that the literal is that real path.
  # sobelow_skip ["Traversal.FileModule"]
  defp dep_file?(deps, string), do: inside_dep?(deps, string, &File.regular?/1)

  # A directory inside some dependency's dir (not the dependency's dir).
  # sobelow_skip ["Traversal.FileModule"]
  defp dep_dir?(deps, string), do: inside_dep?(deps, string, &File.dir?/1)

  defp inside_dep?(deps, string, kind?) when is_binary(deps) and is_binary(string) do
    with :absolute <- Path.type(string),
         real when is_binary(real) <- Context.realpath(string),
         true <- kind?.(real) do
      parts = Path.split(real)
      base = Path.split(deps)
      List.starts_with?(parts, base) and length(parts) - length(base) >= 2
    else
      _ -> false
    end
  end

  defp inside_dep?(_deps, _string, _kind?), do: false
end
