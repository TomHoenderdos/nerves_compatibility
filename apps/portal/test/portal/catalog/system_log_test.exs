defmodule Portal.Catalog.SystemLogTest do
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog.{Ingestion, SystemLog, SystemResult}

  # A *passing* system result on purpose: from Task 3 onwards ingestion creates
  # a SystemLog for failures by itself, which would collide with the uniqueness
  # test below.
  defp passing_system_result do
    dir = Path.join(System.tmp_dir!(), "syslog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, run} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => "slpkg", "version" => "1.0.0"},
          "finished_at" => "2026-09-10T10:00:00Z",
          "systems" => %{"nerves_system_rpi4" => %{"status" => "pass"}}
        },
        %{
          run_id: "slpkg-#{System.unique_integer([:positive])}",
          image_digest: "sha256:x",
          files_dir: dir,
          log: "runner"
        }
      )

    SystemResult
    |> Ash.Query.filter(run_id == ^run.id)
    |> Ash.read_one!(domain: Portal.Catalog)
  end

  defp create_log(attrs) do
    SystemLog
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(domain: Portal.Catalog)
  end

  test "stores a body alongside its pre-truncation size" do
    result = passing_system_result()

    {:ok, log} =
      create_log(%{
        body: "boom",
        byte_size: 900_000,
        truncated: true,
        system_result_id: result.id
      })

    assert log.body == "boom"
    assert log.byte_size == 900_000
    assert log.truncated
  end

  test "allows only one log per system result" do
    result = passing_system_result()
    attrs = %{body: "a", byte_size: 1, truncated: false, system_result_id: result.id}

    assert {:ok, _} = create_log(attrs)
    assert {:error, _} = create_log(attrs)
  end

  test "is loadable from the system result" do
    result = passing_system_result()

    {:ok, _} =
      create_log(%{body: "x", byte_size: 1, truncated: false, system_result_id: result.id})

    loaded =
      SystemResult
      |> Ash.Query.filter(id == ^result.id)
      |> Ash.Query.load(:system_log)
      |> Ash.read_one!(domain: Portal.Catalog)

    assert loaded.system_log.body == "x"
  end

  describe "Portal.Catalog.system_log/2" do
    defp ingest_failed_run(package, log_body, run_id) do
      files = Path.join(System.tmp_dir!(), "csl-f-#{System.unique_integer([:positive])}")
      out = Path.join(System.tmp_dir!(), "csl-o-#{System.unique_integer([:positive])}")
      File.mkdir_p!(files)
      File.mkdir_p!(Path.join(out, "logs"))
      File.write!(Path.join([out, "logs", "nerves_system_rpi4.log"]), log_body)

      on_exit(fn ->
        File.rm_rf(files)
        File.rm_rf(out)
      end)

      {:ok, run} =
        Ingestion.ingest(
          %{
            "package" => %{"name" => package, "version" => "1.0.0"},
            "finished_at" => "2026-09-10T10:00:00Z",
            "systems" => %{"nerves_system_rpi4" => %{"status" => "fail"}}
          },
          %{
            run_id: run_id,
            image_digest: "sha256:x",
            files_dir: files,
            output_dir: out,
            log: "runner"
          }
        )

      run
    end

    test "returns the stored log for the latest run" do
      ingest_failed_run("cslpkg", "older log\n", "cslpkg-1")
      ingest_failed_run("cslpkg", "newer log\n", "cslpkg-2")

      assert {:ok, log} = Portal.Catalog.system_log("cslpkg", "nerves_system_rpi4")

      assert log.body == "newer log\n"
      assert log.status == "fail"
      assert log.run_id == "cslpkg-2"
      assert log.version_tested == "1.0.0"
      assert log.system_pkg == "nerves_system_rpi4"
      refute log.truncated
    end

    test "returns :error for an unknown package" do
      assert Portal.Catalog.system_log("nope", "nerves_system_rpi4") == :error
    end

    test "returns :error for a system with no stored log" do
      ingest_failed_run("cslpkg2", "log\n", "cslpkg2-1")

      assert Portal.Catalog.system_log("cslpkg2", "nerves_system_x86_64") == :error
    end
  end
end
