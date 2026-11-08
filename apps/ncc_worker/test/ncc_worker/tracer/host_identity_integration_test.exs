defmodule NccWorker.Tracer.HostIdentityIntegrationTest do
  @moduledoc """
  A toolchain run's published files are identical to an untraced
  `mix compile` of the same project, on real Hex packages: the run is a real
  `NccWorker.Worker.run/1` (mode "toolchain"), then its `_build/host` is
  moved aside and the same project is compiled untraced, in the same
  directory, and every file under every app's `ebin` and `priv` (and the
  project's consolidated protocols) is compared.

  Identity is `NccWorker.BuildIdentity`'s: every file byte-equal, beams
  chunk by chunk, where a beam's `Dbgi` and `ExCk` chunks only have to
  decode to `===` terms (`exck: :decoded`: on a real package two untraced
  compiles already disagree in `ExCk` bytes, see that module). Nothing is
  left out of the comparison. Needs network access to Hex.pm.

      mix test --include integration apps/ncc_worker/test/ncc_worker/tracer/host_identity_integration_test.exs
  """
  use ExUnit.Case, async: false

  alias NccWorker.BuildIdentity

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: :infinity

  @cases [{"jason", "1.4.5", "include"}, {"phoenix", "1.8.16", "exclude"}]

  # Every env var the run sets in this VM (`NccWorker.HexCache.export_env/1`).
  @env_vars ~w(HEX_HOME NERVES_ARTIFACTS_DIR NERVES_DL_DIR XDG_DATA_HOME)

  for {package, version, variant} <- @cases do
    test "#{package} #{version} (#{variant}) is identical traced and untraced", %{tmp_dir: dir} do
      dir = real(dir)
      work = Path.join(dir, "work")
      seed = Path.join(dir, "hex-cache")
      File.mkdir_p!(Path.join([seed, "packages", "hexpm"]))
      saved = Map.new(@env_vars, &{&1, System.get_env(&1)})
      System.put_env("HEX_HOME", seed)

      try do
        {:ok, result} =
          NccWorker.Worker.run(%{
            run_id: "identity-#{unquote(package)}",
            image: %{name: "identity", digest: "sha256:identity"},
            package: %{name: unquote(package), version: unquote(version)},
            mode: "toolchain",
            optional_deps: unquote(variant),
            paths: %{work_dir: work, output_dir: Path.join(dir, "out")}
          })

        tb = result.toolchain_build
        assert to_string(tb.status) != "error", inspect(tb)

        assert get_in(stringify(tb.compile_observations), ["trace_stats", "judge_compile"]) ==
                 "finished",
               inspect(tb.compile_observations)

        proj = Path.join(work, "proj")
        traced = published(proj)
        assert map_size(traced) > 0
        File.rename!(Path.join(proj, "_build"), Path.join(dir, "traced_build"))

        # The run's own host `HEX_HOME` (`NccWorker.HexHome.prepare/2`).
        env = [
          {"MIX_ENV", "prod"},
          {"MIX_BUILD_PATH", Path.join([proj, "_build", "host"])},
          {"MIX_DEPS_PATH", Path.join(proj, "deps")},
          {"HEX_HOME", Path.join([proj, ".ncc-hex", "host"])}
        ]

        {out, status} = System.cmd("mix", ["compile"], cd: proj, env: env, stderr_to_stdout: true)
        assert status == 0, out
        untraced = published(proj)

        assert Enum.sort(Map.keys(traced)) == Enum.sort(Map.keys(untraced)), out
        assert BuildIdentity.differences(traced, untraced, exck: :decoded) == []
        report(unquote(package), traced, untraced)
      after
        Enum.each(saved, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)

        System.cmd("chmod", ["-R", "u+w", dir], stderr_to_stdout: true)
      end
    end
  end

  # Every file of every built app's `ebin` and `priv`, and of the project's
  # consolidated protocols: path => bytes.
  defp published(proj) do
    lib = Path.join([proj, "_build", "host", "lib"])

    for app <- File.ls!(lib),
        sub <- ["ebin", "priv", "consolidated"],
        file <- Path.wildcard(Path.join([lib, app, sub, "**"]), match_dot: true),
        File.regular?(file),
        into: %{},
        do: {Path.relative_to(file, lib), File.read!(file)}
  end

  # What was compared: files, beams, and the beams whose ExCk bytes differ.
  defp report(package, traced, untraced) do
    beams = for {path, _} <- traced, String.ends_with?(path, ".beam"), do: path
    exck = Enum.count(beams, &(BuildIdentity.beam_difference(traced[&1], untraced[&1]) != nil))

    IO.puts(
      "identity #{package} elixir #{System.version()}: #{map_size(traced)} files, " <>
        "#{length(beams)} beams, #{exck} with ExCk bytes differing (decoded ===)"
    )
  end

  defp stringify(term), do: term |> JSON.encode!() |> JSON.decode!()

  # Mix's relative priv links, computed from an unresolved path, would
  # dangle behind a symlinked tmp dir (the worker's /work is a real path).
  defp real(path) do
    case System.cmd("realpath", [path], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> path
    end
  end
end
