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
            firmware_bytes: 50000,
            file_manifest: %{
              ebin: [
                %{path: "ebin/test.beam", sha256: "abc123", size: 500, mode: 33188}
              ],
              priv: [
                %{path: "priv/data.txt", sha256: "def456", size: 500, mode: 33188}
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
               %{"path" => "ebin/test.beam", "sha256" => "abc123", "size" => 500, "mode" => 33188}
             ]

      assert decoded["package"]["footprint"]["file_manifest"]["priv"] == [
               %{"path" => "priv/data.txt", "sha256" => "def456", "size" => 500, "mode" => 33188}
             ]

      File.rm_rf!(tmp_dir)
    end
  end
end
