defmodule Portal.Catalog.IngestionConfigVariantTest do
  # A toolchain build of a named config variant is stored under its own
  # identity, beside the version's default build, and is published only when
  # it shows its overlay was in effect.
  use Portal.DataCase, async: false

  import Portal.PrecompiledFixtures

  require Ash.Query

  alias Compatibility.ConfigVariants
  alias Portal.Catalog.{Ingestion, ToolchainBuild}

  @lv4 ~w(debug_attributes debug_heex_annotations enable_expensive_runtime_checks root_tag_attribute)

  defp env(values),
    do: for({k, v} <- values, do: %{"app" => "phoenix_live_view", "path" => [k], "value" => v})

  defp default_env, do: env(Enum.map(@lv4, &{&1, unset()}))

  defp unset,
    do: Base.url_encode64(:erlang.term_to_binary(:error, [:deterministic]), padding: false)

  defp prod_env do
    default_env()
    |> Enum.map(fn
      %{"path" => ["root_tag_attribute"]} = i -> %{i | "value" => ConfigVariants.encode("phx-r")}
      i -> i
    end)
  end

  defp rows(name) do
    ToolchainBuild
    |> Ash.Query.filter(package.name == ^name)
    |> Ash.read!(domain: Portal.Catalog)
  end

  # A transient "could not be judged" result: stored as an `:error` row that
  # counts its attempts.
  defp transient(name, opts) do
    result =
      name
      |> toolchain_result("1.0.0", opts)
      |> update_in(["toolchain_build"], fn build ->
        Map.merge(build, %{
          "status" => "skipped",
          "reason" => Compatibility.Portability.could_not_judge(),
          "file_manifest" => nil,
          "compile_observations" => %{
            "trace_stats" => %{"judge_compile" => "not_finished", "transient" => true}
          }
        })
      end)

    {:ok, build} = Ingestion.ingest_toolchain(result, ingest_opts(name, "1.0.0", opts))
    build
  end

  setup do
    drop_legacy_identity_index!()
    :ok
  end

  test "a named variant is its own row beside the default" do
    ingest_toolchain_build("cvpkg", "1.0.0", compile_env: default_env(), compile_env_rule: 1)

    ingest_toolchain_build("cvpkg", "1.0.0",
      config_variant: "phx_prod",
      compile_env: prod_env(),
      compile_env_rule: 1
    )

    assert [
             %{config_variant: "default", status: :pass},
             %{config_variant: "phx_prod", status: :pass}
           ] = "cvpkg" |> rows() |> Enum.sort_by(& &1.config_variant)
  end

  test "an echo-less result for a named job is refused" do
    result = toolchain_result("cvpkg2", "1.0.0", compile_env: prod_env(), compile_env_rule: 1)
    result = update_in(result, ["toolchain_build"], &Map.delete(&1, "config_variant"))

    assert {:error,
            {:identity_mismatch, %{config_variant: "phx_prod"}, %{config_variant: "default"}}} =
             Ingestion.ingest_toolchain(
               result,
               ingest_opts("cvpkg2", "1.0.0", config_variant: "phx_prod")
             )

    assert rows("cvpkg2") == []
  end

  test "a default job refuses a result that says it was built as a named variant" do
    result =
      toolchain_result("cvpkg2b", "1.0.0",
        config_variant: "phx_prod",
        compile_env: prod_env(),
        compile_env_rule: 1
      )

    assert {:error,
            {:identity_mismatch, %{config_variant: "default"}, %{config_variant: "phx_prod"}}} =
             Ingestion.ingest_toolchain(result, ingest_opts("cvpkg2b", "1.0.0"))

    assert rows("cvpkg2b") == []
  end

  test "a named pass that did not record its overlay is skipped, with no files" do
    ingest_toolchain_build("cvpkg3", "1.0.0", compile_env: default_env(), compile_env_rule: 1)

    build =
      ingest_toolchain_build("cvpkg3", "1.0.0",
        config_variant: "phx_prod",
        compile_env: default_env(),
        compile_env_rule: 1
      )

    assert build.status == :skipped

    assert build.reason ==
             "config variant recorded phoenix_live_view root_tag_attribute with another value"

    assert build.file_manifest == nil
  end

  test "a named pass that recorded none of its overlay keys is skipped" do
    build =
      ingest_toolchain_build("cvpkg3b", "1.0.0",
        config_variant: "phx_prod",
        compile_env: [],
        compile_env_rule: 1
      )

    assert build.status == :skipped
    assert build.reason == "config variant did not record its overlay"
    assert build.file_manifest == nil
  end

  test "a named pass without the R5 mark is skipped" do
    build =
      ingest_toolchain_build("cvpkg4", "1.0.0",
        config_variant: "phx_prod",
        compile_env: prod_env()
      )

    assert build.status == :skipped
    assert build.reason == "config variant records no config reads"
  end

  test "a default pass is published without the mark, as before" do
    build = ingest_toolchain_build("cvpkg4b", "1.0.0", compile_env: [])

    assert build.status == :pass
    assert build.file_manifest != nil
  end

  # The default's `:error` row carries a count; a lookup for the named
  # variant of the same identity must not read it.
  test "a transient error of a named variant counts on its own row only" do
    transient("cvpkg5", [])
    transient("cvpkg5", [])
    package_id = hd(rows("cvpkg5")).package_id
    opts = %{version: "1.0.0", toolchain: "1.19/28", builder_version: 1, variant: :with}

    assert Ingestion.previous_transient_attempts(
             package_id,
             Map.put(opts, :config_variant, "phx_prod")
           ) == 0

    assert Ingestion.previous_transient_attempts(package_id, opts) == 2
  end

  # With an `:error` row for both the default and a named variant of one
  # identity, each lookup reads its own row rather than finding two.
  test "transient counts of a default and a named variant stay apart" do
    transient("cvpkg6", [])
    transient("cvpkg6", [])
    named = transient("cvpkg6", config_variant: "phx_prod")

    assert named.status == :error
    assert named.transient_attempts == 1
    package_id = named.package_id
    opts = %{version: "1.0.0", toolchain: "1.19/28", builder_version: 1, variant: :with}

    assert Ingestion.previous_transient_attempts(package_id, opts) == 2

    assert Ingestion.previous_transient_attempts(
             package_id,
             Map.put(opts, :config_variant, "phx_prod")
           ) == 1
  end

  # An `:error` keeps a pass row of its own identity only: a named variant's
  # error neither keeps nor touches the default's pass.
  test "a named variant's error is stored beside a kept default pass" do
    ingest_toolchain_build("cvpkg7", "1.0.0", compile_env: default_env(), compile_env_rule: 1)
    named = transient("cvpkg7", config_variant: "phx_prod")

    assert named.config_variant == "phx_prod"
    assert named.status == :error

    assert [%{config_variant: "default", status: :pass}, %{config_variant: "phx_prod"}] =
             "cvpkg7" |> rows() |> Enum.sort_by(& &1.config_variant)
  end

  # The release before config variants joined these with "@"; a default row
  # must keep taking exactly that lock, so both releases serialise on it.
  test "a default's lock key is the literal key of the release before" do
    base = %{
      package: "jason",
      version: "1.4.4",
      toolchain: "1.20/29",
      builder_version: 3,
      variant: :without
    }

    assert Ingestion.toolchain_lock_key(base) == "toolchain_build@jason@1.4.4@1.20/29@3@without"

    assert Ingestion.toolchain_lock_key(Map.put(base, :config_variant, "default")) ==
             "toolchain_build@jason@1.4.4@1.20/29@3@without"
  end

  # Revoking a withheld row re-reads it under its identity's lock, which must
  # be the lock its own ingest takes.
  test "marking a row withheld takes the lock its ingest takes" do
    ingest_toolchain_build("cvpkg8", "1.0.0", compile_env: default_env(), compile_env_rule: 1)

    ingest_toolchain_build("cvpkg8", "1.0.0",
      config_variant: "phx_prod",
      compile_env: prod_env(),
      compile_env_rule: 1
    )

    for row <-
          ToolchainBuild
          |> Ash.Query.filter(package.name == "cvpkg8")
          |> Ash.Query.load(:package)
          |> Ash.read!(domain: Portal.Catalog) do
      job =
        "cvpkg8"
        |> ingest_opts("1.0.0", config_variant: row.config_variant)
        |> Map.put(:variant, :with)

      assert Ingestion.toolchain_lock_key(Portal.Catalog.toolchain_lock_identity(row)) ==
               Ingestion.toolchain_lock_key(job)
    end
  end

  test "a default's lock key is unchanged; a named one's differs" do
    base = %{package: "p", version: "1", toolchain: "1.19/28", builder_version: 1, variant: :with}
    Portal.Repo.transaction(fn -> assert :ok = Ingestion.lock_toolchain_identity(base) end)
    assert Ingestion.toolchain_lock_key(base) == "toolchain_build@p@1@1.19/28@1@with"

    assert Ingestion.toolchain_lock_key(Map.put(base, :config_variant, "default")) ==
             "toolchain_build@p@1@1.19/28@1@with"

    assert Ingestion.toolchain_lock_key(Map.put(base, :config_variant, "phx_dev")) ==
             "toolchain_build@p@1@1.19/28@1@with@phx_dev"
  end
end
