defmodule Portal.PinnedFixtures do
  @moduledoc false
  # Pinned builds' test fixtures (`Portal.Catalog.PinnedBuild`): a set, the
  # result.json a pinned run writes, and the ingest's options.

  require Ash.Query

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Portal.Catalog
  alias Portal.Catalog.{ArtifactMembership, Ingestion}

  @a String.duplicate("a", 64)
  @b String.duplicate("b", 64)

  def sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  def unique,
    do:
      "pnpkg_#{System.unique_integer([:positive])}_#{Base.encode16(:crypto.strong_rand_bytes(3))}"

  def tmp(name) do
    dir = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  def files(blobs) do
    dir = tmp("pn-files")
    Enum.each(blobs, &File.write!(Path.join(dir, sha(&1)), &1))
    dir
  end

  def pins(
        name,
        deps \\ [
          %{"name" => "decimal", "hex" => "decimal", "version" => "2.3.0", "checksum" => @b}
        ]
      ) do
    hash =
      Compatibility.Pins.hash(%{
        package: name,
        version: "1.0.0",
        package_checksum: @a,
        deps: deps
      })

    %{"hash" => hash, "package_checksum" => @a, "deps" => deps}
  end

  def entry(path, bytes),
    do: %{"path" => path, "sha256" => sha(bytes), "size" => byte_size(bytes), "mode" => 33_188}

  # A pinned run's result.json: the build's lock is `lock`, its files `beams`.
  def result(name, pins, opts \\ []) do
    beams = Keyword.get(opts, :beams, ["beam-" <> name])

    build = %{
      "status" => Keyword.get(opts, :status, "pass"),
      "reason" => Keyword.get(opts, :reason),
      "elixir" => "1.20.5",
      "otp" => "28",
      "deps_lock" => Keyword.get(opts, :lock, Compatibility.Pins.to_lock(pins["deps"])),
      "package_checksum" => @a,
      "declared" => [],
      "manager" => "mix",
      "compile_env" => [],
      "compile_env_rule" => Keyword.get(opts, :compile_env_rule, 1),
      "compile_inputs" => [],
      "built_priv" => [],
      "portability_rule" => 2,
      "judge_revision" => 29,
      "compile_observations" => Keyword.get(opts, :observations, %{}),
      "file_manifest" => %{
        "ebin" => Enum.with_index(beams, &entry("ebin/m#{&2}.beam", &1)),
        "priv" => []
      }
    }

    %{
      "scope" => "toolchain",
      "finished_at" => "2026-11-19T10:00:00Z",
      "package" => %{"name" => name, "version" => "1.0.0"},
      "systems" => %{},
      "requested_optional_deps" => Keyword.get(opts, :echo, "pinned"),
      "optional_deps" => %{"added" => [], "dropped" => [], "skipped" => [], "reason" => "pinned"},
      "pins" => %{"hash" => Keyword.get(opts, :hash, pins["hash"]), "status" => "reproduced"},
      "toolchain_build" => build
    }
    |> then(&if(opts[:sibling], do: Map.put(&1, "deterministic_build", opts[:sibling]), else: &1))
  end

  def opts(name, pins, files_dir) do
    %{
      package: name,
      version: "1.0.0",
      pin_hash: pins["hash"],
      pins: pins,
      target: "pure_elixir",
      run_id: "pn-#{System.unique_integer([:positive])}",
      image_digest: "sha256:pn",
      files_dir: files_dir,
      output_dir: files_dir,
      toolchain: "1.20/28",
      builder_version: Portal.Toolchains.builder_version()
    }
  end

  def ingest(name, pins, opts \\ []) do
    beams = Keyword.get(opts, :beams, ["beam-" <> name])
    Ingestion.ingest_pinned(result(name, pins, opts), opts(name, pins, files(beams)))
  end

  # A pinned firmware run's result.json (phase 2): the target `target` at
  # `system_version`, its files `beams` and `priv` (`{path, bytes}`), the
  # run's lock `lock`. `build_root:` is the worker's R2 verdict on the
  # target (`NccWorker.FirmwareBuildRoot.outcome()`); a "skipped" one drops
  # `file_manifest`, as the worker's own `apply_own/3` does.
  def firmware_result(name, pins, opts \\ []) do
    beams = Keyword.get(opts, :beams, ["beam-" <> name])
    priv = Keyword.get(opts, :priv, [])
    target = Keyword.get(opts, :target, "nerves_system_rpi4")
    build_root = Keyword.get(opts, :build_root)

    sys =
      %{
        "status" => Keyword.get(opts, :status, "pass"),
        "duration_sec" => 90.0,
        "firmware_size_bytes" => 1_000_000,
        "log_tail" => Keyword.get(opts, :log_tail, "built"),
        "system_version" => Keyword.get(opts, :system_version, "2.1.2"),
        "compile_env" => [],
        "compile_inputs" => [],
        "toolchain" => %{
          "package" => "nerves_toolchain_aarch64_nerves_linux_gnu",
          "version" => "15.3.1"
        },
        "otp_full" => "29.0.6",
        "error" => Keyword.get(opts, :error),
        "beam_scan" => %{
          "footprint" => %{
            "file_manifest" => firmware_manifest(build_root, beams, priv)
          }
        }
      }
      |> put_build_root(build_root)

    %{
      "scope" => Keyword.get(opts, :scope, "targets"),
      "finished_at" => "2026-11-19T11:00:00Z",
      "package" => %{"name" => name, "version" => "1.0.0"},
      "toolchain" => %{"elixir" => "1.20.5", "erlang" => Keyword.get(opts, :otp, "29")},
      "systems" =>
        %{"host" => %{"status" => "pass"}}
        |> Map.merge(Keyword.get(opts, :systems, %{target => sys})),
      "deps_lock" => Keyword.get(opts, :lock, Compatibility.Pins.to_lock(pins["deps"])),
      "package_checksum" => @a,
      "declared" => [],
      "requested_optional_deps" => Keyword.get(opts, :echo, "pinned"),
      "optional_deps" => %{"added" => [], "dropped" => [], "skipped" => [], "reason" => "pinned"},
      "pins" => %{
        "hash" => Keyword.get(opts, :hash, pins["hash"]),
        "status" => Keyword.get(opts, :pins_status, "reproduced")
      }
    }
  end

  # The worker withholds a withheld target's files at the source
  # (`NccWorker.FirmwareBuildRoot.apply_own/3` deletes
  # `footprint.file_manifest`), so a "skipped" `build_root` never ships one.
  defp firmware_manifest(%{"status" => "skipped"}, _beams, _priv), do: nil

  defp firmware_manifest(_build_root, beams, priv) do
    %{
      "ebin" => Enum.with_index(beams, &entry("ebin/m#{&2}.beam", &1)),
      "priv" => Enum.map(priv, fn {path, bytes} -> entry(path, bytes) end)
    }
  end

  defp put_build_root(sys, nil), do: sys
  defp put_build_root(sys, build_root), do: Map.put(sys, "build_root", build_root)

  def firmware_opts(name, pins, files_dir) do
    name
    |> opts(pins, files_dir)
    |> Map.merge(%{target: "nerves_system_rpi4", system_version: "2.1.2", toolchain: "1.20/29"})
  end

  def ingest_firmware(name, pins, opts \\ []) do
    blobs =
      Keyword.get(opts, :beams, ["beam-" <> name]) ++ Enum.map(opts[:priv] || [], &elem(&1, 1))

    job = name |> firmware_opts(pins, files(blobs)) |> Map.merge(Map.new(opts[:job] || []))
    Ingestion.ingest_pinned(firmware_result(name, pins, opts), job)
  end

  def shas(row) do
    ArtifactMembership
    |> Ash.Query.filter(pinned_build_id == ^row.id)
    |> Ash.read!(domain: Catalog)
    |> Enum.map(& &1.sha256)
  end

  # An Erlang module holding `?FILE`, compiled without and with the option.
  def beam_pair(name) do
    dir = Path.join(System.tmp_dir!(), "pn-src-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "m0.erl")
    File.write!(path, "-module(m0).\n-export([f/0]).\nf() -> {?FILE, #{inspect(name)}}.\n")
    {erl(path, []), erl(path, [:deterministic])}
  end

  defp erl(path, opts) do
    {:ok, _, beam} = :compile.file(String.to_charlist(path), [:binary, :debug_info | opts])
    beam
  end
end
