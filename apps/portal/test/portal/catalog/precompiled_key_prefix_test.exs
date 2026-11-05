defmodule Portal.Catalog.PrecompiledKeyPrefixTest do
  # A client installs a manifest's `ebin` entries into the package's ebin and
  # its `priv` entries into priv, and a build's priv files are checked on the
  # host only as priv files. So an entry is published only under the key its
  # own path names: an `ebin/` path under `ebin`, a `priv/` path under `priv`.
  # A build with any entry under the other key publishes nothing.
  use Portal.DataCase, async: false

  import Portal.PrecompiledFixtures

  alias Portal.{Catalog, Repo}

  defp set_manifest!(build, manifest) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE catalog_toolchain_builds SET file_manifest = $1 WHERE id = $2",
      [manifest, Ecto.UUID.dump!(build.id)]
    )
  end

  defp beam_entry(build), do: build.file_manifest["ebin"] |> hd()

  defp served?(name, version) do
    case Catalog.precompiled_manifest_v2(name) do
      %{"versions" => %{^version => %{"builds" => [_ | _]}}} -> true
      _ -> false
    end
  end

  test "a build whose entries sit under their own key is served" do
    name = "kp_ok_#{System.unique_integer([:positive])}"
    ingest_toolchain_build(name, "0.3.0")

    assert served?(name, "0.3.0")
  end

  test "a priv/ path listed under ebin publishes nothing" do
    name = "kp_priv_in_ebin_#{System.unique_integer([:positive])}"
    build = ingest_toolchain_build(name, "0.3.0")
    entry = %{beam_entry(build) | "path" => "priv/run.js"}

    set_manifest!(build, %{"ebin" => [entry], "priv" => []})

    refute served?(name, "0.3.0")
  end

  test "an ebin/ path listed under priv publishes nothing" do
    name = "kp_ebin_in_priv_#{System.unique_integer([:positive])}"
    build = ingest_toolchain_build(name, "0.3.0")
    entry = beam_entry(build)

    set_manifest!(build, %{"ebin" => [], "priv" => [entry]})

    refute served?(name, "0.3.0")
  end
end
