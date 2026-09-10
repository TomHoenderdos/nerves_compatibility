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
end
