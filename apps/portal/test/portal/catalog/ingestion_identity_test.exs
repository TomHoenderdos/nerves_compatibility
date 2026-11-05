defmodule Portal.Catalog.IngestionIdentityTest do
  # Ingest checks the result against the job it was enqueued for, so every
  # caller has to say what that job was: `ingest/2` its package and version,
  # `ingest_toolchain/2` its package, version and toolchain. A call that does
  # not is refused before anything is staged or written; the result's own
  # identity is never used in its place.
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.ArtifactStore
  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, Package, Run, ToolchainBuild}

  defp sha(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp unique(prefix),
    do:
      "#{prefix}_#{System.unique_integer([:positive])}_#{Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)}"

  defp files_dir_with(contents) do
    dir = Path.join(System.tmp_dir!(), "ingest-identity-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(contents, &File.write!(Path.join(dir, sha(&1)), &1))
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp entry(path, content),
    do: %{
      "path" => path,
      "sha256" => sha(content),
      "size" => byte_size(content),
      "mode" => 33_188
    }

  defp run_result(name, beam) do
    %{
      "package" => %{"name" => name, "version" => "1.0.0"},
      "finished_at" => "2026-11-05T10:00:00Z",
      "scope" => "full",
      "systems" => %{
        "host" => %{
          "status" => "pass",
          "beam_scan" => %{
            "footprint" => %{"file_manifest" => %{"ebin" => [entry("ebin/#{name}.beam", beam)]}}
          }
        }
      }
    }
  end

  defp toolchain_result(name, beam) do
    %{
      "scope" => "toolchain",
      "finished_at" => "2026-11-05T10:00:00Z",
      "package" => %{"name" => name, "version" => "1.0.0"},
      "systems" => %{},
      "toolchain_build" => %{
        "status" => "pass",
        "reason" => nil,
        "elixir" => "1.19.1",
        "otp" => "28",
        "deps_lock" => %{},
        "package_checksum" => "outer",
        "compile_env" => [],
        "file_manifest" => %{"ebin" => [entry("ebin/#{name}.beam", beam)], "priv" => []}
      }
    }
  end

  defp run_opts(files_dir, extra) do
    Map.merge(
      %{
        run_id: "id-#{System.unique_integer([:positive])}",
        image_digest: "sha256:identity",
        files_dir: files_dir,
        output_dir: files_dir,
        log: "l"
      },
      extra
    )
  end

  defp toolchain_opts(files_dir, extra) do
    Map.merge(
      %{
        run_id: "tc-#{System.unique_integer([:positive])}",
        image_digest: "sha256:identity",
        files_dir: files_dir,
        output_dir: files_dir,
        toolchain: "1.19/28",
        builder_version: 1
      },
      extra
    )
  end

  defp package?(name),
    do: Package |> Ash.Query.filter(name == ^name) |> Ash.exists?(domain: Catalog)

  defp runs_of(name),
    do: Run |> Ash.Query.filter(package.name == ^name) |> Ash.read!(domain: Catalog)

  defp toolchain_rows_of(name),
    do: ToolchainBuild |> Ash.Query.filter(package.name == ^name) |> Ash.read!(domain: Catalog)

  # Nothing was staged: the blob is still in the build's files dir and never
  # reached the artifact store.
  defp assert_unstaged(files_dir, beam) do
    assert File.exists?(Path.join(files_dir, sha(beam)))
    refute ArtifactStore.present?(sha(beam))
  end

  describe "ingest/2" do
    for {label, extra} <- [
          {"without :package or :version", %{}},
          {"without :package", %{version: "1.0.0"}},
          {"without :version", %{package: :result_name}},
          {"with a blank :package", %{package: "", version: "1.0.0"}},
          {"with a blank :version", %{package: :result_name, version: ""}}
        ] do
      @extra extra
      test "refuses a call #{label}, and writes nothing" do
        name = unique("idreq")
        beam = "beam-#{name}"
        files_dir = files_dir_with([beam])
        extra = Map.new(@extra, fn {k, v} -> {k, if(v == :result_name, do: name, else: v)} end)

        assert {:error, {:identity_missing, missing}} =
                 Ingestion.ingest(run_result(name, beam), run_opts(files_dir, extra))

        assert missing != []
        assert Enum.all?(missing, &(&1 in [:package, :version]))
        assert runs_of(name) == []
        refute package?(name)
        assert_unstaged(files_dir, beam)
      end
    end

    test "names every identity key the call is missing" do
      name = unique("idkeys")
      beam = "beam-#{name}"

      assert {:error, {:identity_missing, [:package, :version]}} =
               Ingestion.ingest(run_result(name, beam), run_opts(files_dir_with([beam]), %{}))
    end
  end

  describe "ingest_toolchain/2" do
    for {label, extra} <- [
          {"without :package", %{version: "1.0.0"}},
          {"without :version", %{package: :result_name}},
          {"without :toolchain", %{package: :result_name, version: "1.0.0", toolchain: nil}},
          {"with a blank :package", %{package: "", version: "1.0.0"}}
        ] do
      @extra extra
      test "refuses a call #{label}, and writes nothing" do
        name = unique("tcreq")
        beam = "beam-#{name}"
        files_dir = files_dir_with([beam])
        extra = Map.new(@extra, fn {k, v} -> {k, if(v == :result_name, do: name, else: v)} end)

        assert {:error, {:identity_missing, missing}} =
                 Ingestion.ingest_toolchain(
                   toolchain_result(name, beam),
                   toolchain_opts(files_dir, extra)
                 )

        assert missing != []
        assert Enum.all?(missing, &(&1 in [:package, :version, :toolchain]))
        assert toolchain_rows_of(name) == []
        refute package?(name)
        assert_unstaged(files_dir, beam)
      end
    end
  end
end
