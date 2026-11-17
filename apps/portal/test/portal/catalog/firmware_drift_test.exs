defmodule Portal.Catalog.FirmwareDriftTest do
  use ExUnit.Case, async: true

  alias Portal.Catalog.ClosureDrift
  alias Portal.Catalog.FirmwareDrift

  @built ~U[2026-11-10 00:00:00Z]
  @released ~U[2026-11-12 00:00:00Z]

  defp entry(name, versions, opts \\ []) do
    %{
      name: name,
      latest_version: List.last(versions),
      updated_at: Keyword.get(opts, :updated_at, @released),
      versions: versions,
      retired: []
    }
  end

  defp release(version, deps) do
    deps =
      for {package, requirement} <- deps,
          do: %{package: package, requirement: requirement, optional: false, repository: "hexpm"}

    %{version: version, retired?: false, outer_checksum: nil, deps: deps}
  end

  # `exqlite 0.43.0` -> `telemetry ~> 1.0`; telemetry 1.4.3 is out.
  defp releases do
    releases = %{
      "exqlite" => [release("0.43.0", [{"telemetry", "~> 1.0"}])],
      "telemetry" => [release("1.4.2", []), release("1.4.3", [])]
    }

    fn name ->
      case Map.fetch(releases, name) do
        {:ok, list} -> {:ok, list}
        :error -> {:error, :not_found}
      end
    end
  end

  defp index(extra \\ []) do
    ClosureDrift.index([
      entry("exqlite", ["0.43.0"]),
      entry("telemetry", ["1.4.2", "1.4.3"]),
      entry("nerves_system_rpi4", ["2.1.2", "2.2.1", "2.2.2", "3.0.0"]),
      entry("nerves_system_x86_64", ["1.35.1", "1.35.2"]) | extra
    ])
  end

  defp lock(telemetry), do: %{"telemetry" => %{"version" => telemetry, "checksum" => "x"}}

  # A beam-only build of `system` at `system_version`, current unless told.
  defp target(system, system_version, opts \\ []) do
    Map.merge(
      %{
        system: system,
        system_version: system_version,
        native: false,
        portable: true,
        toolchain_pkg: "nerves_toolchain_aarch64_nerves_linux_gnu",
        toolchain_version: "15.3.1",
        otp_full: "29.1.2",
        elf_needs: nil,
        deps_lock: lock("1.4.3"),
        built_at: @built,
        host_served: false
      },
      Map.new(opts)
    )
  end

  defp run(targets), do: %{package: "exqlite", version: "0.43.0", targets: targets}

  defp judge(targets, systems \\ %{}),
    do: FirmwareDrift.judge(run(targets), index(), releases(), systems)

  describe "closure drift" do
    test "rebuilds the targets whose lock a fresh resolve now locks newer" do
      targets = [
        target("nerves_system_rpi4", "2.2.2", deps_lock: lock("1.4.2")),
        target("nerves_system_x86_64", "1.35.2", deps_lock: lock("1.4.2"))
      ]

      assert {:rebuild, ["nerves_system_rpi4", "nerves_system_x86_64"], changes} = judge(targets)
      assert changes == [%{"dep" => "telemetry", "from" => "1.4.2", "to" => "1.4.3"}]
    end

    test "only the targets that drifted: a target with its own, current lock is left out" do
      targets = [
        target("nerves_system_rpi4", "2.2.2", deps_lock: lock("1.4.2")),
        target("nerves_system_x86_64", "1.35.2")
      ]

      assert {:rebuild, ["nerves_system_rpi4"], _changes} = judge(targets)
    end

    test "a target built after the release is current: its resolve saw it" do
      targets = [
        target("nerves_system_rpi4", "2.2.2",
          deps_lock: lock("1.4.2"),
          built_at: ~U[2026-11-13 00:00:00Z]
        )
      ]

      assert judge(targets) == :current
    end

    test "a closure that cannot be read is not judged" do
      targets = [
        target("nerves_system_rpi4", "2.2.2",
          deps_lock: %{"gone" => %{"version" => "1.0.0", "checksum" => "x"}}
        )
      ]

      run = run(targets)
      index = index([entry("gone", ["1.0.0", "1.1.0"])])

      assert {:error, {:releases, "gone", :not_found}} =
               FirmwareDrift.judge(run, index, releases(), %{})
    end
  end

  # The systems table (`Portal.Precompiled.SystemAbi.table/0`) of rpi4 2.2.2.
  defp systems(overrides \\ %{}) do
    entry =
      Map.merge(
        %{
          "toolchain" => %{
            "package" => "nerves_toolchain_aarch64_nerves_linux_gnu",
            "version" => "15.3.1",
            "series" => "15.3"
          },
          "otp" => "29.1.2",
          "libs" => %{"libc.so.6" => ["GLIBC_2.17", "GLIBC_2.38"]}
        },
        overrides
      )

    %{"nerves_system_rpi4" => %{"2.2.2" => entry}}
  end

  # A native, portable build on rpi4 2.1.2 (OTP 29.0.6) that needs glibc.
  defp native(opts \\ []) do
    target(
      "nerves_system_rpi4",
      "2.1.2",
      [native: true, otp_full: "29.0.6", elf_needs: %{"libc.so.6" => ["GLIBC_2.17"]}] ++ opts
    )
  end

  @bump %{"dep" => "nerves_system_rpi4", "from" => "2.1.2", "to" => "2.2.2"}

  describe "a newer release of the system" do
    test "rebuilds a build that is only used on its own release" do
      for facts <- [[portable: false], [native: nil, portable: nil]] do
        assert {:rebuild, ["nerves_system_rpi4"], [@bump]} = judge([native(facts)], systems())
      end
    end

    test "leaves a beam-only build alone: it is used on any release" do
      assert judge([target("nerves_system_rpi4", "2.1.2")], systems()) == :current
    end

    test "leaves a portable native build the new release can take" do
      assert judge([native()], systems()) == :current
    end

    test "rebuilds a portable native build the new release cannot take" do
      other_series = %{
        "toolchain" => %{
          "package" => "nerves_toolchain_aarch64_nerves_linux_gnu",
          "version" => "15.4.0",
          "series" => "15.4"
        }
      }

      for overrides <- [other_series, %{"otp" => "29.0.1"}, %{"libs" => %{}}] do
        assert {:rebuild, ["nerves_system_rpi4"], [@bump]} =
                 judge([native()], systems(overrides))
      end

      # Needs a symbol version the new release's glibc does not define.
      needs = %{"libc.so.6" => ["GLIBC_2.39"]}
      assert {:rebuild, _, [@bump]} = judge([native(elf_needs: needs)], systems())
    end

    test "waits while the new release is not in the systems table" do
      assert judge([native()], %{}) == :current
      assert judge([native()], systems(%{"libs" => nil})) == :current
    end

    test "only within the series a fresh resolve picks from, and only once" do
      # rpi4 3.0.0 is out too: the bump goes to 2.2.2, not past the major.
      assert {:rebuild, _, [%{"to" => "2.2.2"}]} = judge([native(portable: false)], systems())

      on_newest = native(portable: false, system_version: "2.2.2")
      assert judge([on_newest], systems()) == :current

      # Built after the system last changed: that resolve saw 2.2.2.
      later = native(portable: false, built_at: ~U[2026-11-13 00:00:00Z])
      assert judge([later], systems()) == :current
    end

    test "a drifted lock and a bump are one rebuild with both reasons" do
      drifted = native(portable: false, deps_lock: lock("1.4.2"))

      assert {:rebuild, ["nerves_system_rpi4"], changes} = judge([drifted], systems())

      assert changes == [
               @bump,
               %{"dep" => "telemetry", "from" => "1.4.2", "to" => "1.4.3"}
             ]
    end
  end

  describe "what a rebuild would add" do
    test "a beam-only target is left to the host build that serves it" do
      served = [deps_lock: lock("1.4.2"), host_served: true]

      targets = [
        target("nerves_system_rpi4", "2.2.2", served),
        target("nerves_system_x86_64", "1.35.2", [native: true] ++ served),
        target("nerves_system_bbb", "2.31.2", deps_lock: lock("1.4.2"), host_served: false)
      ]

      assert {:rebuild, ["nerves_system_bbb", "nerves_system_x86_64"], _changes} = judge(targets)
      assert judge([target("nerves_system_rpi4", "2.2.2", served)]) == :current
    end

    test "a target built before locks were recorded is rebuilt, once" do
      unrecorded = %{"dep" => "*", "from" => "unrecorded", "to" => "recorded"}

      before =
        target("nerves_system_rpi4", "2.2.2", deps_lock: nil, built_at: ~U[2026-09-29 11:24:04Z])

      assert {:rebuild, ["nerves_system_rpi4"], [^unrecorded]} = judge([before])

      # Since then a missing lock is one the worker could not read: a
      # rebuild would come back without one again.
      assert judge([target("nerves_system_rpi4", "2.2.2", deps_lock: nil)]) == :current
    end
  end
end
