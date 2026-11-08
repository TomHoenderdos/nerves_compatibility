defmodule Portal.PrecompiledFixtures do
  @moduledoc """
  Fixtures for precompiled artifact tests.
  """

  import ExUnit.Callbacks

  alias Portal.ArtifactStore
  alias Portal.Catalog.Ingestion

  @fixture Path.join([__DIR__, "..", "fixtures", "result.json"])

  @doc """
  Ingests a result with a precompiled artifact file.
  """
  def ingest_with_artifact(result \\ result_fixture()) do
    sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
    _ = File.rm(ArtifactStore.blob_path(sha))
    dir = Path.join(System.tmp_dir!(), "catalog-api-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, sha), "precompiled-beam")
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _run} =
      Ingestion.ingest(result, %{
        package: result["package"]["name"],
        version: result["package"]["version"],
        run_id: result["run_id"],
        image_digest: "sha256:precompiled",
        files_dir: dir,
        scan_request_id: nil,
        log: "api log"
      })

    result
  end

  @doc """
  Ingests a passing toolchain build of `name` `version` with one ebin file,
  whose blob lands in the artifact store. Returns the `ToolchainBuild`.

  Options: `:toolchain` (`"1.19/28"`), `:elixir` (`"1.19.1"`), `:otp` (`"28"`),
  `:builder_version` (1), `:finished_at` (`"2026-10-24T10:00:00Z"`),
  `:deps_lock`, `:package_checksum` (`"outer"`), `:compile_env` (`[]`),
  `:compile_env_rule` (nil, the result's R5 mark: 1 when `compile_env` also
  lists the closure's traced config reads), `:status` (`"pass"`),
  `:mode` (`33_188`), `:config_variant` (`"default"`, both the result's echo
  and the job's value).
  """
  def ingest_toolchain_build(name, version, opts \\ []) do
    content = "toolchain-beam-#{name}-#{version}-#{System.unique_integer([:positive])}"
    sha = Base.encode16(:crypto.hash(:sha256, content), case: :lower)
    dir = tmp_files_dir()
    File.write!(Path.join(dir, sha), content)

    result = toolchain_result(name, version, Keyword.put(opts, :content, content))

    {:ok, build} =
      Ingestion.ingest_toolchain(result, ingest_opts(name, version, [files_dir: dir] ++ opts))

    build
  end

  @doc """
  The `result.json` `ingest_toolchain_build/3` ingests, with the same options,
  plus `:content` (the one ebin file's bytes).
  """
  def toolchain_result(name, version, opts \\ []) do
    content = Keyword.get(opts, :content, "toolchain-beam-#{name}-#{version}")
    sha = Base.encode16(:crypto.hash(:sha256, content), case: :lower)

    deps_lock =
      Keyword.get(opts, :deps_lock, %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}})

    %{
      "scope" => "toolchain",
      "finished_at" => Keyword.get(opts, :finished_at, "2026-10-24T10:00:00Z"),
      "package" => %{"name" => name, "version" => version},
      "systems" => %{},
      "toolchain_build" => %{
        "status" => Keyword.get(opts, :status, "pass"),
        "reason" => nil,
        "elixir" => Keyword.get(opts, :elixir, "1.19.1"),
        "otp" => Keyword.get(opts, :otp, "28"),
        "deps_lock" => deps_lock,
        "package_checksum" => Keyword.get(opts, :package_checksum, "outer"),
        "compile_env" => Keyword.get(opts, :compile_env, []),
        "compile_env_rule" => Keyword.get(opts, :compile_env_rule),
        "config_variant" => Keyword.get(opts, :config_variant, "default"),
        "file_manifest" => %{
          "ebin" => [
            %{
              "path" => "ebin/#{name}.beam",
              "sha256" => sha,
              "size" => byte_size(content),
              "mode" => Keyword.get(opts, :mode, 33_188)
            }
          ],
          "priv" => []
        }
      }
    }
  end

  @doc """
  The job opts `ingest_toolchain_build/3` ingests with: `:toolchain`,
  `:builder_version` and `:config_variant` as there, and `:files_dir` (a new
  empty directory when absent).
  """
  def ingest_opts(name, version, opts \\ []) do
    dir = Keyword.get_lazy(opts, :files_dir, &tmp_files_dir/0)

    %{
      package: name,
      version: version,
      run_id: "tc-#{System.unique_integer([:positive])}",
      image_digest: "sha256:toolchain",
      files_dir: dir,
      output_dir: dir,
      toolchain: Keyword.get(opts, :toolchain, "1.19/28"),
      builder_version: Keyword.get(opts, :builder_version, 1),
      config_variant: Keyword.get(opts, :config_variant, "default")
    }
  end

  defp tmp_files_dir do
    dir = Path.join(System.tmp_dir!(), "toolchain-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  @doc """
  Drops the toolchain build identity's legacy five-column index inside the
  test's sandbox transaction (rolled back with it), so a test can store a
  second config variant of one identity. Callers are `async: false`.
  """
  def drop_legacy_identity_index! do
    Portal.Repo.query!("DROP INDEX IF EXISTS #{Portal.Catalog.ToolchainIdentity.legacy_index()}")
    :ok
  end

  defp result_fixture do
    @fixture |> File.read!() |> Jason.decode!()
  end
end
