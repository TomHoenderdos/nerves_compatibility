defmodule NccWorker.JsonWriterTest do
  use ExUnit.Case, async: true

  alias NccWorker.JsonWriter

  describe "write_result/2" do
    test "writes result.json atomically" do
      tmp_dir = System.tmp_dir!() |> Path.join("ncc_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)

      result = %{
        run_id: "test_001",
        package: %{name: "jason", version: "1.4.1"},
        image: %{name: "test/image", digest: "sha256:abc"},
        toolchain: %{elixir: "1.15.0", erlang: "26", mix: "1.15.0", nerves_bootstrap: nil},
        systems: %{
          "nerves_system_rpi4" => %{
            status: :pass,
            duration_sec: 100.0,
            firmware_size_bytes: 1000,
            log_tail: "log content",
            error: nil
          }
        },
        finished_at: "2025-12-24T10:00:00Z"
      }

      assert :ok = JsonWriter.write_result(tmp_dir, result)

      result_file = Path.join(tmp_dir, "result.json")
      assert File.exists?(result_file)

      {:ok, content} = File.read(result_file)
      decoded = JSON.decode!(content)

      assert decoded["run_id"] == "test_001"
      assert decoded["package"]["name"] == "jason"
      assert decoded["systems"]["nerves_system_rpi4"]["status"] == "pass"

      File.rm_rf!(tmp_dir)
    end

    test "converts status atoms to strings" do
      tmp_dir = System.tmp_dir!() |> Path.join("ncc_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)

      result = %{
        run_id: "test_002",
        package: %{name: "test", version: "1.0.0"},
        image: %{name: "test/image", digest: "sha256:abc"},
        toolchain: %{elixir: "1.15.0", erlang: "26", mix: "1.15.0", nerves_bootstrap: nil},
        systems: %{
          "nerves_system_rpi4" => %{
            status: :fail,
            duration_sec: 50.0,
            firmware_size_bytes: nil,
            log_tail: "error log",
            error: "build failed"
          }
        },
        finished_at: "2025-12-24T10:00:00Z"
      }

      assert :ok = JsonWriter.write_result(tmp_dir, result)

      result_file = Path.join(tmp_dir, "result.json")
      {:ok, content} = File.read(result_file)
      decoded = JSON.decode!(content)

      assert decoded["systems"]["nerves_system_rpi4"]["status"] == "fail"

      File.rm_rf!(tmp_dir)
    end

    test "includes file manifest in package footprint" do
      tmp_dir = System.tmp_dir!() |> Path.join("ncc_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)

      result = %{
        run_id: "test_003",
        package: %{
          name: "test",
          version: "1.0.0",
          footprint: %{
            file_count: 2,
            total_bytes: 1000,
            firmware_bytes: 50_000,
            file_manifest: %{
              ebin: [
                %{path: "ebin/test.beam", sha256: "abc123", size: 500, mode: 33_188}
              ],
              priv: [
                %{path: "priv/data.txt", sha256: "def456", size: 500, mode: 33_188}
              ]
            }
          }
        },
        image: %{name: "test/image", digest: "sha256:abc"},
        toolchain: %{elixir: "1.15.0", erlang: "26", mix: "1.15.0", nerves_bootstrap: nil},
        systems: %{
          "nerves_system_rpi4" => %{
            status: :pass,
            duration_sec: 100.0,
            firmware_size_bytes: 1000,
            log_tail: "log content",
            error: nil
          }
        },
        finished_at: "2025-12-24T10:00:00Z"
      }

      assert :ok = JsonWriter.write_result(tmp_dir, result)

      result_file = Path.join(tmp_dir, "result.json")
      {:ok, content} = File.read(result_file)
      decoded = JSON.decode!(content)

      assert decoded["package"]["footprint"]["file_manifest"]["ebin"] == [
               %{
                 "path" => "ebin/test.beam",
                 "sha256" => "abc123",
                 "size" => 500,
                 "mode" => 33_188
               }
             ]

      assert decoded["package"]["footprint"]["file_manifest"]["priv"] == [
               %{"path" => "priv/data.txt", "sha256" => "def456", "size" => 500, "mode" => 33_188}
             ]

      File.rm_rf!(tmp_dir)
    end

    test "writes the argus result, and null when absent" do
      tmp_dir = System.tmp_dir!() |> Path.join("ncc_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      base = %{
        run_id: "r",
        package: %{name: "p", version: "1"},
        image: %{name: "i", digest: "d"},
        toolchain: %{},
        systems: %{},
        finished_at: "2026-10-03T00:00:00Z"
      }

      argus = %{NccWorker.Argus.skipped() | status: :ok, findings: [%{"title" => "t"}]}
      assert :ok = JsonWriter.write_result(tmp_dir, Map.put(base, :argus, argus))
      decoded = tmp_dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
      assert decoded["argus"]["status"] == "ok"
      assert decoded["argus"]["findings"] == [%{"title" => "t"}]

      assert :ok = JsonWriter.write_result(tmp_dir, base)
      decoded = tmp_dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
      assert Map.has_key?(decoded, "argus")
      assert decoded["argus"] == nil
    end

    test "writes the dependency lock, and omits it when the worker could not read one" do
      dir = Path.join(System.tmp_dir!(), "jw_deps_lock_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      base = %{
        run_id: "r",
        package: %{name: "p", version: "1"},
        image: %{name: "i", digest: "d"},
        toolchain: %{},
        systems: %{},
        finished_at: "2026-10-20T00:00:00Z"
      }

      deps_lock = %{"spark" => %{"version" => "2.7.8", "checksum" => "abc"}}
      :ok = JsonWriter.write_result(dir, Map.put(base, :deps_lock, deps_lock))
      decoded = dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
      assert decoded["deps_lock"] == deps_lock

      :ok = JsonWriter.write_result(dir, base)
      decoded = dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
      refute Map.has_key?(decoded, "deps_lock")
    end

    test "writes what the optional-deps pass did, and omits it for argus-only runs" do
      dir = Path.join(System.tmp_dir!(), "jw_optional_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      base = %{
        run_id: "r",
        package: %{name: "p", version: "1"},
        image: %{name: "i", digest: "d"},
        toolchain: %{},
        systems: %{},
        finished_at: "2026-10-20T00:00:00Z"
      }

      optional_deps = %{added: ["decimal"], dropped: [], reason: nil}
      :ok = JsonWriter.write_result(dir, Map.put(base, :optional_deps, optional_deps))
      decoded = dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()

      assert decoded["optional_deps"] == %{
               "added" => ["decimal"],
               "dropped" => [],
               "reason" => nil
             }

      :ok = JsonWriter.write_result(dir, base)
      decoded = dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
      refute Map.has_key?(decoded, "optional_deps")
    end

    test "writes the package checksum, and omits it when unreadable" do
      dir = Path.join(System.tmp_dir!(), "jw_pkg_checksum_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      base = %{
        run_id: "r",
        package: %{name: "p", version: "1"},
        image: %{name: "i", digest: "d"},
        toolchain: %{},
        systems: %{},
        finished_at: "2026-10-20T00:00:00Z"
      }

      :ok = JsonWriter.write_result(dir, Map.put(base, :package_checksum, "abc"))
      decoded = dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
      assert decoded["package_checksum"] == "abc"

      :ok = JsonWriter.write_result(dir, base)
      decoded = dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
      refute Map.has_key?(decoded, "package_checksum")
    end

    test "aggregates cache candidates across systems and dedupes by key" do
      dir = Path.join(System.tmp_dir!(), "jw_cache_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      candidate = %{
        "key" => String.duplicate("a", 64),
        "dep" => "pkg",
        "dep_lock" => "1.0.0 aa",
        "target" => "rpi4",
        "elixir" => "1.20.3",
        "otp" => "29",
        "closure" => [%{"name" => "dep", "lock" => "2.0.0 cc"}]
      }

      result = %{
        run_id: "r",
        package: %{name: "pkg", version: "1.0.0"},
        image: %{name: "i", digest: "d"},
        toolchain: %{},
        systems: %{
          "nerves_system_rpi4" => %{
            status: :pass,
            duration_sec: 1.0,
            firmware_size_bytes: 1,
            log_tail: "",
            error: nil,
            cache_candidates: [candidate]
          },
          "nerves_system_bbb" => %{
            status: :pass,
            duration_sec: 1.0,
            firmware_size_bytes: 1,
            log_tail: "",
            error: nil,
            cache_candidates: [candidate]
          },
          "host" => %{
            status: :pass,
            duration_sec: 1.0,
            firmware_size_bytes: nil,
            log_tail: "",
            error: nil,
            cache_candidates: []
          }
        },
        finished_at: "2026-10-24T00:00:00Z"
      }

      assert :ok = JsonWriter.write_result(dir, result)
      decoded = dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()

      assert decoded["cache"]["candidates"] == [candidate]
    end

    test "omits cache from result.json when no system produced a candidate" do
      dir = Path.join(System.tmp_dir!(), "jw_no_cache_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      result = %{
        run_id: "r",
        package: %{name: "pkg", version: "1.0.0"},
        image: %{name: "i", digest: "d"},
        toolchain: %{},
        systems: %{
          "nerves_system_rpi4" => %{
            status: :fail,
            duration_sec: 1.0,
            firmware_size_bytes: nil,
            log_tail: "",
            error: "boom",
            cache_candidates: []
          }
        },
        finished_at: "2026-10-24T00:00:00Z"
      }

      assert :ok = JsonWriter.write_result(dir, result)
      decoded = dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()

      refute Map.has_key?(decoded, "cache")
    end

    test "writes the run scope, so ingestion knows what the run left out" do
      dir = Path.join(System.tmp_dir!(), "jw_scope_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      result = %{
        run_id: "r1",
        package: %{name: "jason", version: "1.4.4"},
        image: %{name: "i", digest: "d"},
        toolchain: %{},
        systems: %{},
        finished_at: "2026-10-11T00:00:00Z",
        argus: nil,
        scope: "argus_only"
      }

      :ok = NccWorker.JsonWriter.write_result(dir, result)

      assert dir
             |> Path.join("result.json")
             |> File.read!()
             |> JSON.decode!()
             |> Map.fetch!("scope") ==
               "argus_only"
    end

    test "writes egress_probe when the run probed, and omits it otherwise" do
      tmp_dir = System.tmp_dir!() |> Path.join("ncc_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      base = %{
        run_id: "egress",
        package: %{name: "jason", version: "1.4.4"},
        image: %{name: "test/image", digest: "sha256:abc"},
        toolchain: %{elixir: "1.20.0", erlang: "29", mix: "1.20.0", nerves_bootstrap: nil},
        systems: %{},
        finished_at: "2026-10-25T10:00:00Z"
      }

      probe = [
        %{
          "address" => "192.0.2.11",
          "port" => 5432,
          "family" => "inet",
          "outcome" => "timeout"
        }
      ]

      assert :ok = JsonWriter.write_result(tmp_dir, Map.put(base, :egress_probe, probe))
      decoded = tmp_dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
      assert decoded["egress_probe"] == probe

      assert :ok = JsonWriter.write_result(tmp_dir, base)
      decoded = tmp_dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
      refute Map.has_key?(decoded, "egress_probe")
    end
  end

  describe "nerves_cache" do
    defp nerves_result(extra) do
      Map.merge(
        %{
          run_id: "r-nerves",
          package: %{name: "jason", version: "1.4.4"},
          image: %{name: "ncc-worker:local", digest: "sha256:x"},
          toolchain: %{elixir: "1.20.3", erlang: "29", mix: "1.20.3", nerves_bootstrap: "1.17.3"},
          systems: %{},
          finished_at: "2026-10-25T10:00:00Z"
        },
        extra
      )
    end

    @tag :tmp_dir
    test "writes a build's misses and locked Nerves packages", %{tmp_dir: dir} do
      report = %{
        misses: [%{"name" => "nerves_system_rpi4", "version" => "2.0.0"}],
        lock: [%{"name" => "nerves_system_rpi4", "version" => "2.0.0"}]
      }

      assert :ok = JsonWriter.write_result(dir, nerves_result(%{nerves_cache: report}))

      decoded = dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()

      assert decoded["nerves_cache"] == %{
               "misses" => [%{"name" => "nerves_system_rpi4", "version" => "2.0.0"}],
               "lock" => [%{"name" => "nerves_system_rpi4", "version" => "2.0.0"}]
             }
    end

    @tag :tmp_dir
    test "leaves the key out when the run has no report", %{tmp_dir: dir} do
      assert :ok = JsonWriter.write_result(dir, nerves_result(%{}))

      decoded = dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
      refute Map.has_key?(decoded, "nerves_cache")
    end

    @tag :tmp_dir
    test "a warm run writes its warm report and a null package", %{tmp_dir: dir} do
      warm = %{installed: ["nerves_system_rpi4-2.0.0"], resolved: ["nerves_system_rpi4-2.0.0"]}

      assert :ok =
               JsonWriter.write_result(
                 dir,
                 nerves_result(%{package: nil, scope: "warm_nerves", warm: warm})
               )

      decoded = dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()

      assert decoded["package"] == nil
      assert decoded["scope"] == "warm_nerves"
      assert decoded["warm"]["installed"] == ["nerves_system_rpi4-2.0.0"]
    end
  end

  describe "per-system optional dependencies" do
    defp system(extra) do
      Map.merge(
        %{
          status: :pass,
          duration_sec: 1.0,
          firmware_size_bytes: 1,
          log_tail: "",
          error: nil
        },
        extra
      )
    end

    defp with_systems(systems) do
      %{
        run_id: "r-opt",
        package: %{name: "ecto", version: "3.14.2"},
        image: %{name: "ncc-worker:local", digest: "sha256:x"},
        toolchain: %{elixir: "1.20.3", erlang: "29", mix: "1.20.3", nerves_bootstrap: "1.17.3"},
        systems: systems,
        finished_at: "2026-10-27T10:00:00Z"
      }
    end

    @tag :tmp_dir
    test "writes a system's own deps_lock and optional_deps", %{tmp_dir: dir} do
      kept =
        system(%{
          deps_lock: %{"jason" => %{"version" => "1.4.4", "checksum" => "o-jason"}},
          optional_deps: %{added: ["jason"], dropped: [], reason: nil}
        })

      dropped =
        system(%{optional_deps: %{added: [], dropped: ["jason"], reason: "timeout"}})

      result =
        with_systems(%{
          "nerves_system_x86_64" => kept,
          "nerves_system_rpi4" => dropped,
          "nerves_system_bbb" => system(%{status: :fail})
        })

      assert :ok = JsonWriter.write_result(dir, result)

      systems =
        dir |> Path.join("result.json") |> File.read!() |> JSON.decode!() |> Map.get("systems")

      assert systems["nerves_system_x86_64"]["deps_lock"] == %{
               "jason" => %{"version" => "1.4.4", "checksum" => "o-jason"}
             }

      assert systems["nerves_system_x86_64"]["optional_deps"] == %{
               "added" => ["jason"],
               "dropped" => [],
               "reason" => nil
             }

      refute Map.has_key?(systems["nerves_system_rpi4"], "deps_lock")
      assert systems["nerves_system_rpi4"]["optional_deps"]["reason"] == "timeout"
      refute Map.has_key?(systems["nerves_system_bbb"], "deps_lock")
      refute Map.has_key?(systems["nerves_system_bbb"], "optional_deps")
    end
  end
end
