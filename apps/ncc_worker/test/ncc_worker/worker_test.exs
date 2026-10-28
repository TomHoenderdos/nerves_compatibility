defmodule NccWorker.WorkerTest do
  use ExUnit.Case, async: true

  alias NccWorker.{Systems, Worker}

  @moduletag :tmp_dir

  @systems [
    %{name: "nerves_system_rpi0", target: "rpi0"},
    %{name: "nerves_system_x86_64", target: "x86_64"}
  ]

  # `setup_paths/1` creates `<output_dir>/logs` before `prepare_project/1`
  # ever runs; mirror that precondition here.
  defp context(output_dir) do
    File.mkdir_p!(Path.join(output_dir, "logs"))

    %{
      input: %{run_id: "run-1", package: %{name: "sample"}, image: "ncc-worker:test"},
      paths: %{output_dir: output_dir},
      toolchain: %{elixir: "1.19.1", erlang: "28", mix: "1.19.1", nerves_bootstrap: "present"},
      log_tail_bytes: 4096,
      description: "Sample package",
      github_url: nil,
      package_version_hint: "1.0.0"
    }
  end

  describe "deps_get_verdict/3" do
    test "a transient deps.get failure stays an {:error, _} tuple to retry", %{tmp_dir: tmp_dir} do
      output =
        "** (Mix) Request failed (:nxdomain)\nCould not fetch record for sample from registry.hex.pm\n"

      assert {:error, {:deps_get_failed, ^output}} =
               Worker.deps_get_verdict(context(tmp_dir), @systems, output)

      refute File.exists?(Path.join([tmp_dir, "logs", "nerves_system_rpi0.log"]))
    end

    test "a deterministic deps.get failure (a dependency's mix.exs raising) is a normal verdict",
         %{tmp_dir: tmp_dir} do
      output = """
      ** (RuntimeError) reckon_db supports Erlang/OTP 28; this is OTP 29.
          (reckon_db 2.3.0) mix.exs:4: Reckon.Db.MixProject.__info__/1
      """

      assert {:ok, result} = Worker.deps_get_verdict(context(tmp_dir), @systems, output)

      assert result.run_id == "run-1"
      assert result.package.name == "sample"
      assert result.package.version == "1.0.0"
      assert result.scope == "full"
      assert map_size(result.systems) == 2

      for system <- @systems do
        entry = Map.fetch!(result.systems, system.name)
        assert entry.status == :error
        assert entry.error == "deps_get_failed"
        assert entry.log_tail =~ "reckon_db supports Erlang/OTP 28"

        log_path = Path.join([tmp_dir, "logs", "#{system.name}.log"])
        assert File.read!(log_path) == output
      end
    end

    test "respects systems_filter: only the filtered systems get a verdict and a log", %{
      tmp_dir: tmp_dir
    } do
      output =
        "** (Mix) No package with name totally_not_a_real_package (>= 0.0.0) found in registry\n"

      systems = Systems.select(["nerves_system_rpi0"])

      assert {:ok, result} = Worker.deps_get_verdict(context(tmp_dir), systems, output)

      assert Map.keys(result.systems) == ["nerves_system_rpi0"]
      assert File.exists?(Path.join([tmp_dir, "logs", "nerves_system_rpi0.log"]))
    end

    test "deterministic verdict carries no host key, unlike a built run", %{tmp_dir: tmp_dir} do
      output = "could not find a version that satisfies >= 1.0.0 and <= 0.5.0 for jason\n"

      assert {:ok, result} = Worker.deps_get_verdict(context(tmp_dir), @systems, output)

      refute Map.has_key?(result.systems, "host")
    end

    # An argus_only run only ever follows a same-version full run
    # (`Portal.Workers.Build.scope_args/3` pins `latest_version_tested(package)`
    # against the requested version before it will pick this mode). A
    # deterministic verdict here must not name any system: ingestion's
    # carry-forward (`Portal.Catalog.Ingestion.carry_candidates/4`) only
    # copies systems the new run did NOT report, so naming them with
    # `status: :error` would overwrite the previous run's real statuses --
    # flipping a passing package to error from an advisory sweep. Argus
    # itself is advisory and never changes a status.
    test "argus_only scope: deterministic verdict has no systems and argus is skipped with a reason",
         %{tmp_dir: tmp_dir} do
      output = """
      ** (RuntimeError) reckon_db supports Erlang/OTP 28; this is OTP 29.
          (reckon_db 2.3.0) mix.exs:4: Reckon.Db.MixProject.__info__/1
      """

      ctx = Map.update!(context(tmp_dir), :input, &Map.put(&1, :mode, "argus_only"))

      assert {:ok, result} = Worker.deps_get_verdict(ctx, @systems, output)

      assert result.scope == "argus_only"
      assert result.systems == %{}
      assert result.argus.status == :skipped
      assert result.argus.reason == "deps_get_failed"

      refute File.exists?(Path.join([tmp_dir, "logs", "nerves_system_rpi0.log"]))
      refute File.exists?(Path.join([tmp_dir, "logs", "nerves_system_x86_64.log"]))
    end
  end
end
