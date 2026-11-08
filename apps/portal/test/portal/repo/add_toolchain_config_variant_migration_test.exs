defmodule Portal.Repo.AddToolchainConfigVariantMigrationTest do
  use ExUnit.Case, async: true

  @path Path.expand(
          "../../../priv/repo/migrations/20261108085139_add_toolchain_config_variant.exs",
          __DIR__
        )
  @migration Portal.Repo.Migrations.AddToolchainConfigVariant

  setup_all do
    unless Code.ensure_loaded?(@migration), do: Code.compile_file(@path)
    :ok
  end

  test "runs in a transaction, which SET LOCAL needs" do
    refute @migration.__migration__()[:disable_ddl_transaction]
  end

  test "bounds its lock wait both ways, before any DDL" do
    source = File.read!(@path)

    for direction <- ["def up do", "def down do"] do
      [_, body] = String.split(source, direction, parts: 2)
      [first | _] = body |> String.trim_leading() |> String.split("\n", parts: 2)
      assert first =~ ~s{execute("SET LOCAL lock_timeout = '5s'")}
    end
  end
end
