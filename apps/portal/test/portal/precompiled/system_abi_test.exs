defmodule Portal.Precompiled.SystemAbiTest do
  use Portal.DataCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]
  import Portal.PrecompiledFixtures

  alias Portal.Catalog.SystemAbi, as: Row
  alias Portal.Precompiled.SystemAbi
  alias Portal.Test.FakeHexDeps

  @toolchain "nerves_toolchain_aarch64_nerves_linux_gnu"

  describe "series_from_requirement/1" do
    test "a ~> X.Y.Z requirement is the X.Y series" do
      assert SystemAbi.series_from_requirement("~> 15.3.0") == "15.3"
      assert SystemAbi.series_from_requirement("~> 15.3.2") == "15.3"
    end

    test "every other requirement shape is nil" do
      for requirement <- [
            "~> 15.3",
            ">= 15.3.0",
            "== 15.3.1",
            "15.3.1",
            "~> 15.3.0 or ~> 15.4.0",
            "",
            "~> 15.3.0-rc.0"
          ] do
        assert SystemAbi.series_from_requirement(requirement) == nil, requirement
      end
    end

    test "a non-string is nil" do
      assert SystemAbi.series_from_requirement(nil) == nil
      assert SystemAbi.series_from_requirement(15.3) == nil
      assert SystemAbi.series_from_requirement(%{"requirement" => "~> 15.3.0"}) == nil
    end
  end

  defp lock_row!(system, version, attrs \\ %{}) do
    {:ok, row} =
      %{
        system_pkg: system,
        version: version,
        source: "lock",
        toolchain_pkg: @toolchain,
        toolchain_version: "15.3.1",
        otp: "28.1.2",
        libs: %{"libc.so.6" => ["GLIBC_2.17", "GLIBC_2.41"]}
      }
      |> Map.merge(attrs)
      |> Row.observe()

    row
  end

  # The fixture run's rpi4 result, made a published native build needing `needs`.
  defp native_result!(needs) do
    ingest_with_artifact()

    Repo.query!(
      "UPDATE catalog_system_results SET native = true, portable = true, elf_needs = $1 " <>
        "WHERE system_pkg = 'nerves_system_rpi4'",
      [needs]
    )
  end

  defp release(version, requirement) do
    %{
      version: version,
      retired?: false,
      outer_checksum: nil,
      deps: [
        %{package: "nerves", requirement: "~> 1.10", optional: false, repository: "hexpm"},
        %{package: @toolchain, requirement: requirement, optional: false, repository: "hexpm"}
      ]
    }
  end

  defp hex_releases!(map), do: Process.put({FakeHexDeps, :releases}, map)

  describe "sync_requirements/0" do
    test "writes a requirement row for every newer Hex release without one" do
      lock_row!("nerves_system_rpi4", "2.2.2")
      native_result!(%{"libc.so.6" => ["GLIBC_2.17"]})

      hex_releases!(%{
        "nerves_system_rpi4" => [
          release("2.2.0", "~> 15.2.0"),
          release("2.2.2", "~> 15.3.0"),
          release("2.3.0", "~> 15.4.0"),
          release("2.4.0-junk.1.2", "~> 15.4.0"),
          release("nonsense", "~> 15.4.0"),
          release("2.5.0", "~> 15")
        ]
      })

      assert SystemAbi.sync_requirements() == :ok

      rpi4 = SystemAbi.table()["nerves_system_rpi4"]
      assert Map.keys(rpi4) |> Enum.sort() == ["2.2.2", "2.3.0", "2.5.0"]

      assert rpi4["2.3.0"] == %{
               "toolchain" => %{"package" => @toolchain, "version" => nil, "series" => "15.4"},
               "otp" => nil,
               "libs" => nil
             }

      assert rpi4["2.5.0"]["toolchain"]["series"] == nil

      assert rpi4["2.2.2"]["toolchain"] == %{
               "package" => @toolchain,
               "version" => "15.3.1",
               "series" => "15.3"
             }

      assert rpi4["2.2.2"]["otp"] == "28.1.2"

      # A second sync changes nothing.
      assert SystemAbi.sync_requirements() == :ok
      assert SystemAbi.table()["nerves_system_rpi4"] == rpi4
    end

    test "a system without a published native build is left alone" do
      lock_row!("nerves_system_rpi4", "2.2.2")
      ingest_with_artifact()
      hex_releases!(%{"nerves_system_rpi4" => [release("2.3.0", "~> 15.4.0")]})

      assert SystemAbi.sync_requirements() == :ok
      assert Map.keys(SystemAbi.table()["nerves_system_rpi4"]) == ["2.2.2"]
    end

    test "a Hex failure is skipped" do
      lock_row!("nerves_system_rpi4", "2.2.2")
      native_result!(%{"libc.so.6" => []})
      hex_releases!(%{})

      assert capture_log(fn -> assert SystemAbi.sync_requirements() == :ok end) =~
               "Could not read the Hex releases of nerves_system_rpi4"

      assert Map.keys(SystemAbi.table()["nerves_system_rpi4"]) == ["2.2.2"]
    end
  end

  describe "table/0" do
    test "is empty without rows" do
      assert SystemAbi.table() == %{}
    end

    test "keeps only the libraries published builds of the system need and the toolchain's" do
      lock_row!("nerves_system_rpi4", "2.2.2", %{
        libs: %{
          "libc.so.6" => ["GLIBC_2.17"],
          "libz.so.1" => ["ZLIB_1.2.9"],
          "libfoo.so.1" => [],
          "ld-linux-aarch64.so.1" => ["GLIBC_2.17"],
          "libstdc++.so.6" => ["GLIBCXX_3.4"]
        }
      })

      native_result!(%{"libz.so.1" => ["ZLIB_1.2.9"]})

      assert SystemAbi.table()["nerves_system_rpi4"]["2.2.2"]["libs"] == %{
               "libc.so.6" => ["GLIBC_2.17"],
               "libz.so.1" => ["ZLIB_1.2.9"],
               "ld-linux-aarch64.so.1" => ["GLIBC_2.17"],
               "libstdc++.so.6" => ["GLIBCXX_3.4"]
             }

      # The database keeps every library.
      [row] = Ash.read!(Row, domain: Portal.Catalog)
      assert Map.has_key?(row.libs, "libfoo.so.1")
    end
  end

  describe "render/0" do
    test "canonical JSON, format 1, named by its SHA-256" do
      lock_row!("nerves_system_rpi4", "2.2.2")
      lock_row!("nerves_system_bbb", "2.20.0", %{toolchain_pkg: "nerves_toolchain_armv7"})

      {sha, body} = SystemAbi.render()
      assert sha == Base.encode16(:crypto.hash(:sha256, body), case: :lower)

      assert %{"format" => 1, "systems" => systems} = Jason.decode!(body)
      assert systems == SystemAbi.table()

      # Keys sorted at every level, no whitespace.
      assert body =~ ~r/\A\{"format":1,"systems":\{"nerves_system_bbb":/
      assert body =~ ~s("2.2.2":{"libs":{"libc.so.6":["GLIBC_2.17","GLIBC_2.41"]},"otp":"28.1.2")

      assert body =~
               ~s("toolchain":{"package":"#{@toolchain}","series":"15.3","version":"15.3.1"})

      assert SystemAbi.render() == {sha, body}
    end

    test "is stored once and read back only while it hashes to its name" do
      lock_row!("nerves_system_rpi4", "2.2.2")
      {sha, body} = SystemAbi.render()

      assert SystemAbi.stored(sha) == :error
      assert SystemAbi.store(sha, body) == :ok
      assert SystemAbi.store(sha, body) == :ok
      assert SystemAbi.stored(sha) == {:ok, body}

      Repo.query!("UPDATE precompiled_system_tables SET body = '{}' WHERE sha256 = $1", [sha])
      assert SystemAbi.stored(sha) == :error
    end
  end
end
