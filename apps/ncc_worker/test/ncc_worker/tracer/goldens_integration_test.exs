defmodule NccWorker.Tracer.GoldensIntegrationTest do
  @moduledoc """
  Golden observations of the compile-time trace (precompiled portability
  spec, section 9) on the real packages the spec read call site by call
  site: each is built as a real toolchain run (`NccWorker.Worker.run/1`,
  mode "toolchain", both optional-dependency variants) on the toolchain this
  VM runs, which fetches the real Hex tarballs into the run's own verified
  Hex cache, takes the lock snapshot before any compile and runs the real
  tracer and judge (`NccWorker.Portability.run/3`).

  Under rule 2 the build's own status is the trace's verdict joined with the
  static rules (`BuildSelection.static_rules/4`), so it is asserted too:
  `pass` exactly where `@expected` says `pass`, `skipped` elsewhere.
  `rule1_reason` records what rule 1 would have said. Also asserted are the
  trace verdict class (`@expected`), and that the normalised observations
  equal the committed golden under
  `test/fixtures/portability_goldens/<os>-elixir-<x.y.z>-otp-<n>/` in every
  part that repeats between identical runs (`stable/1`).
  A golden is compared only while the build resolved the same lock: Hex
  moves on, and a new lock is a reason to regenerate, not a failure. A
  toolchain without a golden of its own is only reported.
  Timings and call counts go to a report under
  `<tmp>/ncc-portability-goldens/`, never into a golden.

      mix test --include integration apps/ncc_worker/test/ncc_worker/tracer/goldens_integration_test.exs

  The same file holds the "no regression" goldens (`@hits`, tag
  `:no_regression`): packages published today that must still judge pass.

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
  # be publishable under the trace ("pass"). Each refused entry names its
  # first refusal (the golden lists them all). These record what the rules
  # do today; they are not loosened here.
  @expected %{
    {"phoenix", "exclude"} => "pass",
    {"phoenix", "include"} => "pass",
    {"phoenix_live_view", "exclude"} => "pass",
    # fine (lazy_html's C++ headers dependency) bakes `deps/fine/c_include`
    # (R2 taint); lazy_html's elixir_make precompiled-NIF download reads the
    # host (open_port, system_info, its download cache).
    {"phoenix_live_view", "include"} => "refused",
    # `embed_templates` calls Phoenix.Template.engines/0 at compile time,
    # which reads `:phoenix_view, :template_engines` (a deprecated fallback).
    # The key is unset and phoenix_view is outside phoenix_template's
    # dependency tree, so whether its .app is loaded when the read happens
    # depends on the consumer's compile order: the value cannot be told, and
    # that is checked before the package's own R2 (`embed_templates
    # "layouts/*"` keeps the template directory in LayoutView), which the
    # golden no longer reaches. Unpublished either way.
    {"phoenix_live_dashboard", "exclude"} => "could_not_judge",
    # The same read first; the optional ecto adapters add exqlite
    # (elixir_make) and decimal (see @hits) host reads.
    {"phoenix_live_dashboard", "include"} => "could_not_judge",
    {"swoosh", "exclude"} => "pass",
    # quic's and hackney's rebar.config run pre_hooks (R3 taint). The reads
    # certifi_pt and parse_trans made through OTP's own code loading
    # (erl_prim_loader) no longer refuse (judge refinements, item 5a).
    {"swoosh", "include"} => "refused",
    # sentry's mix.exs reads SENTRY_INTEGRATION for `test_paths` (line 17),
    # but project/0 ends `++ xref_options()`, an `if` on System.version(),
    # so it is not a keyword list literal (mix.exs rule); and
    # Sentry.OpenTelemetry.VersionChecker calls
    # Application.loaded_applications/0 at compile time.
    {"sentry", "exclude"} => "refused",
    # Outside every window first: a rebar.config.script (gproc's reads
    # os:getenv/1) that Mix evaluates with erl_eval while loading deps. Then
    # the exclude refusals and the closure's taint.
    {"sentry", "include"} => "refused"
  }

  # Packages whose toolchain builds are published hits today (the
  # 2026-11-06 benchmark's Phoenix and library locks), built as published:
  # with their optional dependencies. The trace must not take any of them
  # away: each must judge pass, observations allowed. A refusal or
  # could-not-judge here is a regression, reported, never loosened here.
  @hits [
    {"telemetry", "1.4.2"},
    {"jason", "1.4.5"},
    {"plug", "1.20.3"},
    {"plug_crypto", "2.2.1"},
    {"mime", "2.0.7"},
    {"mint", "1.11.0"},
    {"hpax", "1.1.0"},
    {"finch", "0.24.0"},
    {"nimble_options", "1.2.0"},
    {"nimble_pool", "1.1.0"},
    {"decimal", "3.2.0"},
    {"idna", "7.1.0"},
    {"thousand_island", "1.6.0"},
    {"websock", "0.5.3"},
    {"phoenix_pubsub", "2.4.1"},
    {"phoenix_template", "1.1.0"},
    {"gettext", "1.0.2"},
    {"expo", "1.1.1"},
    {"telemetry_metrics", "1.2.0"},
    {"telemetry_poller", "1.3.0"},
    {"dns_cluster", "0.2.0"},
    # Could not be judged on 1.20 for the type checker's warning colouring
    # read until it was reviewed; served on 1.19.
    {"polymorphic_embed", "5.0.6"}
  ]

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

      expected_status = if @expected[{package, variant}] == "pass", do: "pass", else: "skipped"
      assert golden["status"] == expected_status, inspect(Map.take(golden, ["status", "reason"]))

      if package in ["phoenix", "phoenix_live_view", "swoosh"] do
        assert golden["rule1_reason"] in ["calls System.cmd/2", "calls erlang:open_port/2"],
               inspect(golden["rule1_reason"])
      end

      if {package, variant} == {"phoenix_live_view", "exclude"} do
        assert ~s(phoenix_live_view ["root_tag_attribute"] = :error) in golden["compile_env"],
               inspect(golden["compile_env"])
      end
    end
  end

  for {package, version} <- @hits do
    @tag package: package, version: version, variant: "include", no_regression: true
    test "no regression: #{package} #{version}, published today, still judges pass", ctx do
      %{package: package, version: version} = ctx
      {golden, stats} = build(ctx, package, version, "include")

      report(ctx, golden, stats)
      compare(ctx.tag, golden)

      assert golden["trace_verdict"] == "pass",
             "regression: #{package} #{version} (#{golden["trace_verdict"]}): " <>
               "#{golden["reason"]}\n" <>
               inspect(Map.take(golden["observations"], ["refusals", "taint", "problems"]),
                 pretty: true,
                 limit: :infinity
               )
    end
  end

  # Packages rebar3 builds whose only platform_define regex sees nothing
  # but the OTP major (judge refinements, item 3): poolboy's `"^R"` decides
  # the same on every host of one OTP major, so it passes under rule 2. A
  # regex that sees past the major keeps refusing; rebar_platform_define_test
  # pins that.
  @platform_define_major_only [{"poolboy", "1.5.2"}]

  for {package, version} <- @platform_define_major_only do
    @tag package: package, version: version, variant: "include"
    test "platform_define on the OTP major only: #{package} #{version} passes", ctx do
      %{package: package, version: version} = ctx
      {golden, stats} = build(ctx, package, version, "include")
      report(ctx, golden, stats)

      assert golden["status"] == "pass", inspect(Map.take(golden, ["status", "reason"]))
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
      "compile_env" => decoded_compile_env(tb["compile_env"]),
      "compile_env_rule" => tb["compile_env_rule"],
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

  # The items as `app [path] = value`, values decoded, so a golden shows
  # what a client is matched on.
  defp decoded_compile_env(items) when is_list(items) do
    for %{"app" => app, "path" => path, "value" => value} <- items do
      decoded = value |> Base.url_decode64!(padding: false) |> :erlang.binary_to_term()
      "#{app} #{inspect(path)} = #{inspect(decoded)}"
    end
  end

  defp decoded_compile_env(_items), do: nil

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
  #     of those, so taint compares by dependency only, and a dependency
  #     whose only refusals are such truncated-stack reads is left out
  #     (it is tainted in one run and clean in the next, grpcbox via sentry).
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
      "taint" => stable_taint(obs["taint"], obs["refusals"] || []),
      "problems" => obs["problems"],
      "native_libs" => obs["native_libs"],
      "nif_check" => obs["nif_check"]
    })
  end

  defp stable_taint(taint, refusals) do
    firm =
      for r <- refusals,
          not (r["reason"] =~ "(truncated stack"),
          into: MapSet.new(),
          do: r["owner"]

    taint
    |> Enum.reject(fn {dep, reason} ->
      reason =~ "(truncated stack" and not MapSet.member?(firm, dep)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
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
