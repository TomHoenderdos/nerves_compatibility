defmodule Portal.Catalog.ToolchainIdentityTest do
  use Portal.DataCase, async: false

  import ExUnit.CaptureLog
  import Portal.PrecompiledFixtures, only: [ingest_toolchain_build: 2]

  alias Portal.Catalog.{ToolchainBuild, ToolchainIdentity}
  alias Portal.Repo

  defp row!(package_id, config_variant) do
    ToolchainBuild
    |> Ash.Changeset.for_create(:upsert, %{
      package_id: package_id,
      version: "1.0.0",
      toolchain: "1.19/28",
      builder_version: 1,
      variant: :with,
      config_variant: config_variant,
      status: :pass,
      run_id: "tc-#{config_variant}"
    })
    |> Ash.create!(domain: Portal.Catalog)
  end

  setup do
    build = ingest_toolchain_build("idpkg", "0.1.0")
    %{package_id: build.package_id}
  end

  test "existing and new rows are the default variant", %{package_id: id} do
    assert row!(id, "default").config_variant == "default"
  end

  # The release before config variants upserts with ON CONFLICT on the
  # five-column identity. No unique index matches it any more, so that release
  # cannot write a toolchain build against this schema: every node that runs
  # toolchain builds or their ingest must be on a release that names the
  # six-column identity before the five-column index is dropped.
  test "an upsert shaped like the release before config variants raises", %{package_id: id} do
    row!(id, "default")

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO catalog_toolchain_builds (package_id, version, toolchain, builder_version, variant, status)
          VALUES ($1, '1.0.0', '1.19/28', 1, 'with', 'skipped')
          ON CONFLICT (package_id, version, toolchain, builder_version, variant)
          DO UPDATE SET status = EXCLUDED.status
          """,
          [Ecto.UUID.dump!(id)]
        )
      end

    assert error.postgres.code == :invalid_column_reference
  end

  defmodule ErrorRepo do
    @moduledoc false
    def query(_sql, _params), do: {:error, %Postgrex.Error{message: "connection lost"}}
  end

  defmodule RaisingRepo do
    @moduledoc false
    def query(_sql, _params), do: raise(DBConnection.ConnectionError, "pool timeout")
  end

  test "the gate fails closed when its query errors" do
    log = capture_log(fn -> refute ToolchainIdentity.config_variants_ready?(ErrorRepo) end)
    assert log =~ "config variants stay off"
  end

  test "the gate fails closed when its query raises" do
    log = capture_log(fn -> refute ToolchainIdentity.config_variants_ready?(RaisingRepo) end)
    assert log =~ "config variants stay off"
  end

  test "the legacy index is gone: the gate is open and a named row sits beside the default",
       %{package_id: id} do
    assert ToolchainIdentity.config_variants_ready?()
    a = row!(id, "default")
    b = row!(id, "phx_prod")
    assert a.id != b.id
    # The six-column upsert replaces its own row only.
    assert row!(id, "phx_prod").id == b.id
    assert row!(id, "default").id == a.id
  end

  test "an unknown config variant is refused", %{package_id: id} do
    assert_raise Ash.Error.Invalid, fn -> row!(id, "phx_staging") end
  end
end
