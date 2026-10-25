defmodule NccWorker.BeamScanTest do
  use ExUnit.Case, async: true

  alias NccWorker.BeamScan

  describe "normalize/1" do
    test "an entry without a mode normalizes to \"mode\" => nil, not a fallback" do
      scan = %{
        footprint: %{
          file_count: 1,
          total_bytes: 10,
          ebin: %{file_count: 1, total_bytes: 10},
          priv: %{file_count: 0, total_bytes: 0},
          manifest: [
            %{path: "ebin/x.beam", size: 10, sha256: "abc123"}
          ]
        }
      }

      normalized = BeamScan.normalize(scan)

      assert normalized["footprint"]["file_manifest"]["ebin"] == [
               %{"path" => "ebin/x.beam", "size" => 10, "sha256" => "abc123", "mode" => nil}
             ]
    end

    test "an entry with a mode passes it through unchanged" do
      scan = %{
        footprint: %{
          file_count: 1,
          total_bytes: 10,
          ebin: %{file_count: 0, total_bytes: 0},
          priv: %{file_count: 1, total_bytes: 10},
          manifest: [
            %{path: "priv/tool", size: 10, sha256: "def456", mode: 33_261}
          ]
        }
      }

      normalized = BeamScan.normalize(scan)

      assert normalized["footprint"]["file_manifest"]["priv"] == [
               %{"path" => "priv/tool", "size" => 10, "sha256" => "def456", "mode" => 33_261}
             ]
    end
  end
end
