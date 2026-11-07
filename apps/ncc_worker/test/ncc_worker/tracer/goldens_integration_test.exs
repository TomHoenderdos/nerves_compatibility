defmodule NccWorker.Tracer.GoldensIntegrationTest do
  @moduledoc """
  Golden observations of the compile-time trace (precompiled portability
  spec, section 9) on the real packages the spec read call site by call
  site: each is built as a real toolchain run (`NccWorker.Worker.run/1`,
  mode "toolchain", both optional-dependency variants) on the toolchain this
  VM runs, which fetches the real Hex tarballs into the run's own verified
  Hex cache, takes the lock snapshot before any compile and runs the real
  tracer and judge (`NccWorker.Portability.run/3`).

  P1 only records: the spec expects these packages to become publishable
  under the trace, but rule 1 still refuses them in P1, so the build's own
  status is not asserted. What is asserted is the trace verdict class
  (`@expected`), and that the normalised observations equal the committed
  golden under `test/fixtures/portability_goldens/<os>-elixir-<x.y.z>-otp-<n>/`
  in every part that repeats between identical runs (`stable/1`).
  A golden is compared only while the build resolved the same lock: Hex
  moves on, and a new lock is a reason to regenerate, not a failure. A
  toolchain without a golden of its own is only reported.
  Timings and call counts go to a report under
  `<tmp>/ncc-portability-goldens/`, never into a golden.

      mix test --include integration apps/ncc_worker/test/ncc_worker/tracer/goldens_integration_test.exs

  Needs network access to Hex.pm. `NCC_PORTABILITY_GOLDENS_UPDATE=1` writes
  the goldens instead of comparing them, `NCC_PORTABILITY_GOLDENS_DIR`
  writes them elsewhere, and `NCC_PORTABILITY_GOLDENS_KEEP=1` keeps each
  run's work dir.
  """
  use ExUnit.Case, async: false

  alias Compatibility.Portability, as: Reasons

  @moduletag :integration
  @moduletag timeout: :infinity

  @goldens [
    {"phoenix", "1.8.16"},
    {"phoenix_live_view", "1.2.13"},
    {"phoenix_live_dashboard", "0.8.7"},
    {"swoosh", "1.29.3"},
    {"sentry", "14.0.1"}
  ]

  @variants ["exclude", "include"]

  # The trace verdict class each golden has. The spec expects every one to
  # be publishable under the trace ("pass"); none is in P1. Each entry names
  # the first refusal (the golden lists them all). These record what the
  # rules do today; they are not loosened here (P4 decides).
  @expected %{
    # A closure dependency's rebar.config names plugins: telemetry's test
    # profile `{plugins, [covertool]}` and its `project_plugins` (rebar3
    # static rule, R3 taint). That is the only refusal.
    {"phoenix", "exclude"} => "refused",
    # The same telemetry taint first; cowboy_telemetry's `project_plugins` too.
    {"phoenix", "include"} => "refused",
    # The same telemetry taint, and nothing else.
    {"phoenix_live_view", "exclude"} => "refused",
    # fine (lazy_html's C++ headers dep) bakes `deps/fine/c_include` (R2);
    # lazy_html's elixir_make precompiled-NIF download reads the host.
    {"phoenix_live_view", "include"} => "refused",
    # The package's own R2: `embed_templates "layouts/*"` keeps the template
    # directory `<root>/deps/phoenix_live_dashboard/lib/phoenix/live_dashboard`
    # in Phoenix.LiveDashboard.LayoutView, a directory and not a source file,
    # so the Task 9 bare-source-path observation does not cover it.
    {"phoenix_live_dashboard", "exclude"} => "refused",
    # The same R2 first; ecto's optional adapters add exqlite (elixir_make)
    # and decimal (`:erlang.system_info` in a module body) host reads.
    {"phoenix_live_dashboard", "include"} => "refused",
    # Not judged: idna_data is compiled `-compile(compressed)` (a gzip beam),
    # which the R2 reader takes for "not a beam container"; telemetry's
    # plugins taint too. (Rule 1 refuses it anyway: erlang:open_port/2.)
    {"swoosh", "exclude"} => "could_not_judge",
    # mimerl's `project_plugins` taint first (hackney, certifi, parse_trans,
    # gen_smtp, h2, quic, webtransport and telemetry too), and the idna beam.
    {"swoosh", "include"} => "refused",
    # sentry's mix.exs reads SENTRY_INTEGRATION for `test_paths` (line 17),
    # but project/0 ends `++ xref_options()`, an `if` on System.version(),
    # so it is not a keyword list literal (Task 7 rule); and
    # Sentry.OpenTelemetry.VersionChecker calls Application.loaded_applications/0
    # at compile time.
    {"sentry", "exclude"} => "refused",
    # Outside every window first: gproc's rebar.config.script, which Mix
    # evaluates with erl_eval, reads os:getenv/1 and
    # init:get_plain_arguments/0. Then the exclude refusals, and taint of
    # certifi, parse_trans/hackney, opentelemetry_semantic_conventions and
    # the rebar3 plugin/script rules.
    {"sentry", "include"} => "refused"
  }

  @env_vars ~w(HEX_HOME NERVES_ARTIFACTS_DIR NERVES_DL_DIR XDG_DATA_HOME)

  # The judge's caps on observation lists (`NccWorker.Portability`).
  @caps %{
    "refusals" => 100,
    "config_reads" => 200,
    "elixir_version" => 50,
    "native_calls" => 50,
    "mix_exs_allowed" => 50,
    "build_root_source_path" => 50
  }

  setup_all do
    # The real path: on macOS the tmp dir sits behind the /var symlink, and
    # Mix's relative priv links, computed from the unresolved path, would
    # dangle (the worker's /work is a real path).
    root = Path.join(real(System.tmp_dir!()), "ncc-portability-goldens")
    seed = Path.join(root, "hex-cache")
    File.mkdir_p!(Path.join([seed, "packages", "hexpm"]))
    %{root: root, seed: seed, tag: platform_tag()}
  end

  for {package, version} <- @goldens, variant <- @variants do
    @tag package: package, version: version, variant: variant
    test "#{package} #{version}, optional deps #{variant}", ctx do
      %{package: package, version: version, variant: variant} = ctx
      {golden, stats} = build(ctx, package, version, variant)

      report(ctx, golden, stats)
      compare(ctx.tag, golden)

      assert golden["trace_verdict"] == Map.fetch!(@expected, {package, variant}),
             "#{package} #{version} (#{variant}): " <>
               inspect(Map.take(golden, ["reason", "trace_verdict", "observations"]),
                 pretty: true,
                 limit: :infinity
               )
    end
  end

  # --- the run -----------------------------------------------------------------

  defp build(ctx, package, version, variant) do
    work = Path.join(ctx.root, "run-#{System.os_time(:millisecond)}-#{package}-#{variant}")
    saved = Map.new(@env_vars, &{&1, System.get_env(&1)})
    System.put_env("HEX_HOME", ctx.seed)
    started = System.monotonic_time(:millisecond)

    try do
      {:ok, result} = NccWorker.Worker.run(input(work, package, version, variant))
      total_ms = System.monotonic_time(:millisecond) - started
      result = result |> JSON.encode!() |> JSON.decode!()
      tb = result["toolchain_build"]
      assert is_map(tb), "#{package}: no toolchain_build in #{inspect(result, limit: 30)}"
      assert tb["status"] != "error", "#{package}: host compile failed: #{tb["reason"]}"
      keep_tarballs(work, ctx.seed)

      golden =
        result
        |> golden(tb, package, version, variant, ctx.tag)
        |> normalise(roots(work))

      {golden, stats(tb, total_ms)}
    after
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      unless System.get_env("NCC_PORTABILITY_GOLDENS_KEEP") == "1", do: remove(work)
    end
  end

  defp input(work, package, version, variant) do
    %{
      run_id: "golden-#{package}-#{variant}",
      image: %{name: "golden", digest: "sha256:golden"},
      package: %{name: package, version: version},
      mode: "toolchain",
      optional_deps: variant,
      paths: %{work_dir: Path.join(work, "work"), output_dir: Path.join(work, "out")}
    }
  end

  defp golden(result, tb, package, version, variant, tag) do
    obs = tb["compile_observations"] || %{}

    %{
      "package" => package,
      "version" => version,
      "optional_deps_variant" => variant,
      "platform" => tag,
      "status" => tb["status"],
      "reason" => tb["reason"],
      "rule1_reason" => tb["rule1_reason"],
      "trace_verdict" => trace_verdict(tb),
      "judge_compile" => get_in(obs, ["trace_stats", "judge_compile"]),
      "deps_lock" => lock_versions(tb["deps_lock"]),
      "optional_deps" => Map.take(result["optional_deps"] || %{}, ["added", "dropped", "reason"]),
      "observations" => Map.delete(obs, "trace_stats")
    }
  end

  # The trace's own verdict, read back through `Worker.combine/2`: a trace
  # refusal always wins the reason (a refusal ordered before an unreadable
  # closure beam keeps that beam's problem in the observations), and
  # could-not-judge leaves problems.
  defp trace_verdict(tb) do
    obs = tb["compile_observations"] || %{}

    cond do
      obs == %{} -> "not_traced"
      Reasons.refusal?(tb["reason"]) -> "refused"
      (obs["problems"] || []) != [] -> "could_not_judge"
      tb["reason"] == Reasons.could_not_judge() -> "could_not_judge"
      true -> "pass"
    end
  end

  defp lock_versions(lock) when is_map(lock),
    do: Map.new(lock, fn {name, entry} -> {name, entry["version"]} end)

  defp lock_versions(_lock), do: %{}

  defp stats(tb, total_ms) do
    stats = get_in(tb, ["compile_observations", "trace_stats"]) || %{}
    Map.put(stats, "total_run_ms", total_ms)
  end

  # Tarballs this run downloaded seed the next run's cache (Hex checks
  # each against the registry before using it).
  defp keep_tarballs(work, seed) do
    dir = Path.join([work, "work", "hex-home", "packages", "hexpm"])

    for name <- File.ls!(dir),
        String.ends_with?(name, ".tar"),
        path = Path.join(dir, name),
        File.lstat!(path).type == :regular,
        do: File.cp!(path, Path.join([seed, "packages", "hexpm", name]))
  end

  defp remove(work) do
    System.cmd("chmod", ["-R", "u+w", work], stderr_to_stdout: true)
    File.rm_rf(work)
  end

  # --- normalising ---------------------------------------------------------------

  defp roots(work) do
    elixir = :code.lib_dir(:elixir) |> to_string() |> Path.dirname() |> Path.dirname()

    [
      {work, "<work>"},
      {System.tmp_dir!(), "<tmp>"},
      {elixir, "<elixir>"},
      {to_string(:code.root_dir()), "<otp>"},
      {System.user_home!(), "<home>"}
    ]
    |> Enum.flat_map(fn {path, name} -> [{real(path), name}, {path, name}] end)
    |> Enum.uniq()
    |> Enum.sort_by(fn {path, _} -> -byte_size(path) end)
  end

  defp real(path) do
    case System.cmd("realpath", [path], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> path
    end
  end

  defp normalise(term, roots) when is_map(term),
    do: Map.new(term, fn {k, v} -> {normalise(k, roots), normalise(v, roots)} end)

  defp normalise(term, roots) when is_list(term),
    do: term |> Enum.map(&normalise(&1, roots)) |> Enum.sort_by(&canonical/1)

  # Elixir numbers the modules it evaluates (`elixir_compiler_<n>`) in
  # compile order, which parallel compilation does not fix.
  defp normalise(term, roots) when is_binary(term) do
    roots
    |> Enum.reduce(term, fn {path, name}, acc -> String.replace(acc, path, name) end)
    |> String.replace(~r/elixir_compiler_\d+/, "elixir_compiler_N")
  end

  defp normalise(term, _roots), do: term

  # --- goldens and the report ------------------------------------------------------

  defp compare(tag, golden) do
    path = golden_path(tag, golden)
    body = canonical(golden) <> "\n"
    refute body =~ System.user_home!(), "an unnormalised path in #{path}"

    cond do
      System.get_env("NCC_PORTABILITY_GOLDENS_UPDATE") == "1" ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, body)

      not File.exists?(path) ->
        IO.puts(
          "no golden #{path} for this toolchain; NCC_PORTABILITY_GOLDENS_UPDATE=1 writes it"
        )

      true ->
        compare_file(path, body, golden)
    end
  end

  defp compare_file(path, body, golden) do
    old = JSON.decode!(File.read!(path))
    new = JSON.decode!(body)
    full = full_kinds(old) ++ full_kinds(new)

    if old["deps_lock"] == golden["deps_lock"],
      do: assert(stable(old, full) == stable(new, full), "#{path} differs:\n#{body}"),
      else: IO.puts("#{path}: Hex resolved a different lock, not compared (regenerate)")
  end

  # The part of a golden that repeats run after run. The golden keeps all of
  # it for review, but three parts vary between identical runs:
  #
  #   * a list the judge capped (`@caps`) keeps whichever entries came
  #     first, so a kind that is full in either golden is not compared;
  #   * reads a rebar3 child makes through erl_prim_loader with a truncated
  #     stack come and go with code loading order (grpcbox, certifi), so
  #     refusals with a truncated stack are left out;
  #   * a tainted dependency's reason is its first refusal, which can be one
  #     of those, so taint compares by dependency only.
  defp stable(golden, full) do
    obs = golden["observations"]

    lists =
      for {kind, _cap} <- @caps,
          kind not in full,
          into: %{},
          do: {kind, stable_list(kind, obs[kind] || [])}

    golden
    |> Map.delete("observations")
    |> Map.merge(lists)
    |> Map.merge(%{
      "taint" => obs["taint"] |> Map.keys() |> Enum.sort(),
      "problems" => obs["problems"],
      "native_libs" => obs["native_libs"],
      "nif_check" => obs["nif_check"]
    })
  end

  defp full_kinds(golden),
    do: for({kind, cap} <- @caps, length(golden["observations"][kind] || []) >= cap, do: kind)

  defp stable_list("refusals", list),
    do: Enum.reject(list, &(&1["reason"] =~ "(truncated stack"))

  defp stable_list(_kind, list), do: list

  defp golden_path(tag, golden) do
    dir =
      System.get_env("NCC_PORTABILITY_GOLDENS_DIR") ||
        Path.expand("../../fixtures/portability_goldens", __DIR__)

    name = "#{golden["package"]}-#{golden["version"]}-#{golden["optional_deps_variant"]}.json"
    Path.join([dir, tag, name])
  end

  defp report(ctx, golden, stats) do
    dir = Path.join([ctx.root, "report", ctx.tag])
    File.mkdir_p!(dir)

    row =
      Map.put(
        Map.take(golden, ~w(package version optional_deps_variant status reason trace_verdict)),
        "trace_stats",
        stats
      )

    name = "#{golden["package"]}-#{golden["optional_deps_variant"]}.json"
    File.write!(Path.join(dir, name), canonical(row) <> "\n")

    IO.puts(
      "golden #{ctx.tag} #{golden["package"]} #{golden["optional_deps_variant"]}: " <>
        "trace=#{golden["trace_verdict"]} status=#{golden["status"]} reason=#{golden["reason"]} " <>
        "calls=#{stats["calls"]} wall_ms=#{stats["wall_ms"]} total_ms=#{stats["total_run_ms"]}"
    )
  end

  defp platform_tag do
    {_, os} = :os.type()
    "#{os}-elixir-#{System.version()}-otp-#{System.otp_release()}"
  end

  # JSON with sorted keys, one entry per line: the same term always gives
  # the same bytes.
  defp canonical(term), do: term |> pretty("") |> IO.iodata_to_binary()

  defp pretty(map, _indent) when is_map(map) and map_size(map) == 0, do: "{}"

  defp pretty(map, indent) when is_map(map) do
    inner = indent <> "  "

    entries =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [inner, JSON.encode!(to_string(k)), ": ", pretty(v, inner)] end)
      |> Enum.intersperse(",\n")

    ["{\n", entries, "\n", indent, "}"]
  end

  defp pretty([], _indent), do: "[]"

  defp pretty(list, indent) when is_list(list) do
    inner = indent <> "  "
    entries = list |> Enum.map(&[inner, pretty(&1, inner)]) |> Enum.intersperse(",\n")
    ["[\n", entries, "\n", indent, "]"]
  end

  defp pretty(term, _indent), do: JSON.encode!(term)
end
