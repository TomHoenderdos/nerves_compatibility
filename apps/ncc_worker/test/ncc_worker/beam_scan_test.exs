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

  # A build's `.mix` holds Mix's manifests, the compiler's diagnostics among
  # them, coloured or not by the builder's terminal settings. What a build
  # publishes is its file manifest, which lists `ebin` and `priv` only.
  @tag :tmp_dir
  test "a published file manifest lists ebin and priv only, never .mix", %{tmp_dir: dir} do
    app = Path.join(dir, "fx")
    File.mkdir_p!(Path.join(app, "ebin"))
    File.mkdir_p!(Path.join(app, "priv"))
    File.mkdir_p!(Path.join(app, ".mix"))
    File.write!(Path.join(app, ".mix/compile.elixir"), "diagnostics with \e[31mcolour\e[0m")
    File.write!(Path.join(app, "priv/data.txt"), "data")
    beam = BeamScan |> :code.which() |> List.to_string()
    File.cp!(beam, Path.join(app, "ebin/Elixir.NccWorker.BeamScan.beam"))

    assert {:ok, scan} = BeamScan.analyze_app_dir(app)
    manifest = scan["footprint"]["file_manifest"]

    assert manifest |> Map.keys() |> Enum.sort() == ["ebin", "priv"]
    assert [%{"path" => "ebin/Elixir.NccWorker.BeamScan.beam"}] = manifest["ebin"]
    assert [%{"path" => "priv/data.txt"}] = manifest["priv"]
    refute inspect(manifest) =~ ".mix"
  end
end
