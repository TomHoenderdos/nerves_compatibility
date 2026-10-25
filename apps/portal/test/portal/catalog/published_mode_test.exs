defmodule Portal.Catalog.PublishedModeTest do
  use Portal.DataCase, async: false

  alias Portal.{ArtifactStore, Catalog}
  alias Portal.Catalog.Ingestion

  import Portal.PrecompiledFixtures

  @deps %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}}

  defp sha(content), do: Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  # One run of `name` whose rpi4 manifest carries a priv file per `{path, mode}`.
  defp ingest_run(name, modes) do
    dir = Path.join(System.tmp_dir!(), "pm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    entries =
      for {path, mode} <- [{"ebin/#{name}.beam", 0o100644} | modes] do
        content = "#{name}-#{path}"
        _ = File.rm(ArtifactStore.blob_path(sha(content)))
        File.write!(Path.join(dir, sha(content)), content)
        %{"path" => path, "sha256" => sha(content), "size" => byte_size(content), "mode" => mode}
      end

    {ebin, priv} = Enum.split_with(entries, &String.starts_with?(&1["path"], "ebin/"))

    result = %{
      "run_id" => "pm-#{name}",
      "package" => %{"name" => name, "version" => "1.0.0"},
      "deps_lock" => @deps,
      "package_checksum" => "outer",
      "finished_at" => "2026-10-20T10:00:00Z",
      "toolchain" => %{"elixir" => "1.18.4", "erlang" => "27"},
      "systems" => %{
        "nerves_system_rpi4" => %{
          "status" => "pass",
          "system_version" => "1.24.0",
          "compile_env" => [],
          "beam_scan" => %{
            "footprint" => %{"file_manifest" => %{"ebin" => ebin, "priv" => priv}}
          }
        }
      }
    }

    {:ok, _run} =
      Ingestion.ingest(result, %{
        run_id: result["run_id"],
        image_digest: "sha256:pm",
        files_dir: dir,
        log: "l"
      })
  end

  defp published_modes(files), do: Map.new(files["priv"], &{&1["path"], &1["mode"]})

  test "a run's files publish as exactly 0644 or 0755, from their execute bits" do
    name = "pm_run_#{System.unique_integer([:positive])}"

    ingest_run(name, [
      {"priv/rwxrwxr-x", 0o100775},
      {"priv/rw-rw-r--", 0o100664},
      {"priv/r-xr-xr-x", 0o100555},
      {"priv/rw-------", 0o100600},
      {"priv/bare-rwx", 0o755},
      {"priv/no-mode", nil},
      {"priv/string-mode", "0755"},
      {"priv/setuid", 0o104755},
      {"priv/symlink", 0o120777}
    ])

    expected = %{
      "priv/rwxrwxr-x" => 0o100755,
      "priv/rw-rw-r--" => 0o100644,
      "priv/r-xr-xr-x" => 0o100755,
      "priv/rw-------" => 0o100644,
      "priv/bare-rwx" => 0o100755
    }

    v1 = Catalog.precompiled_manifest(name).versions["1.0.0"]["nerves_system_rpi4"]
    assert published_modes(v1) == expected
    assert [%{"mode" => 0o100644}] = v1["ebin"]

    [v2] = Catalog.precompiled_manifest_v2(name)["versions"]["1.0.0"]["builds"]
    assert published_modes(v2) == expected
  end

  test "a toolchain build's files are normalised the same way" do
    name = "pm_tc_#{System.unique_integer([:positive])}"
    ingest_toolchain_build(name, "0.3.0", mode: 0o100664)

    [build] = Catalog.precompiled_manifest_v2(name)["versions"]["0.3.0"]["builds"]
    assert [%{"mode" => 0o100644}] = build["ebin"]
  end

  test "a toolchain build with a file of no mode is not published" do
    name = "pm_tc_nil_#{System.unique_integer([:positive])}"
    ingest_toolchain_build(name, "0.3.0", mode: nil)

    assert Catalog.precompiled_manifest_v2(name) == nil
  end
end
