defmodule Portal.Catalog.WorldDedupeTest do
  # A world build whose closure came out equal to the version's with or
  # without build adds nothing a client could tell apart: it is stored as a
  # skip with no files, so the same build is never served twice.
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog.{ArtifactMembership, Ingestion, ToolchainBuild}

  @jason %{"jason" => %{"version" => "1.4.4", "checksum" => "j"}}
  @world %{
    "jason" => %{"version" => "1.4.4", "checksum" => "j"},
    "decimal" => %{"version" => "2.3.0", "checksum" => "d"}
  }

  defp sha(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp files_dir(contents) do
    dir = Path.join(System.tmp_dir!(), "world-dedupe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(contents, &File.write!(Path.join(dir, sha(&1)), &1))
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp result(name, deps, beam, echo) do
    %{
      "scope" => "toolchain",
      "finished_at" => "2026-11-14T10:00:00Z",
      "package" => %{"name" => name, "version" => "1.0.0"},
      "systems" => %{},
      "requested_optional_deps" => echo,
      "optional_deps" => %{
        "added" => if(echo == "exclude", do: [], else: Map.keys(deps)),
        "dropped" => [],
        "skipped" => []
      },
      "toolchain_build" => %{
        "status" => "pass",
        "elixir" => "1.19.1",
        "otp" => "28",
        "deps_lock" => deps,
        "package_checksum" => "outer",
        "compile_env" => [],
        "file_manifest" => %{
          "ebin" => [
            %{
              "path" => "ebin/#{name}.beam",
              "sha256" => sha(beam),
              "size" => byte_size(beam),
              "mode" => 33_188
            }
          ]
        }
      }
    }
  end

  defp ingest!(name, variant, deps, echo) do
    beam = "beam-#{name}-#{variant}-#{map_size(deps)}"

    {:ok, row} =
      Ingestion.ingest_toolchain(result(name, deps, beam, echo), %{
        package: name,
        version: "1.0.0",
        run_id: "tc-#{System.unique_integer([:positive])}",
        image_digest: "sha256:toolchain",
        files_dir: files_dir([beam]),
        output_dir: System.tmp_dir!(),
        toolchain: "1.19/28",
        builder_version: 1,
        variant: variant
      })

    {row, sha(beam)}
  end

  defp member?(sha),
    do:
      ArtifactMembership
      |> Ash.Query.filter(sha256 == ^sha)
      |> Ash.exists?(domain: Portal.Catalog)

  test "a world build with the with build's closure is a skip with no files" do
    ingest!("dup_with", :with, @world, "include")
    {row, sha} = ingest!("dup_with", :world_phx, @world, "world:phx")

    assert %ToolchainBuild{status: :skipped, reason: "same closure as the with build"} = row
    assert row.file_manifest == nil
    refute member?(sha)
  end

  test "a world build with the without build's closure is a skip too" do
    ingest!("dup_without", :with, @world, "include")
    ingest!("dup_without", :without, @jason, "exclude")

    {row, _sha} = ingest!("dup_without", :world_phx, @jason, "world:phx")
    assert %{status: :skipped, reason: "same closure as the without build"} = row
  end

  test "a world build with a closure of its own passes and keeps its files" do
    ingest!("own", :with, @jason, "include")
    {row, sha} = ingest!("own", :world_phx, @world, "world:phx")

    assert %{status: :pass, reason: nil} = row
    assert member?(sha)
  end

  test "a revoked with build of the same closure does not make the world build redundant" do
    {with_row, _} = ingest!("revoked", :with, @world, "include")
    with_row |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Portal.Catalog)

    {row, _sha} = ingest!("revoked", :world_phx, @world, "world:phx")
    assert row.status == :pass
  end

  test "a with build is never compared, whatever its closure" do
    ingest!("plain", :without, @world, "exclude")
    {row, _sha} = ingest!("plain", :with, @world, "include")
    assert row.status == :pass
  end
end
