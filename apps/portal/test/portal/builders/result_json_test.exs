defmodule Portal.Builders.ResultJsonTest do
  use ExUnit.Case, async: true

  alias Portal.Builders.ResultJson

  defp write(name, content) do
    dir = Path.join(System.tmp_dir!(), "result-json-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, content)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  defp deeply_nested(depth) do
    Enum.reduce(1..depth, "0", fn _, acc -> "[" <> acc <> "]" end)
  end

  test "reads and decodes a small, shallow result.json" do
    path = write("result.json", ~s({"package":{"name":"jason"}}))

    assert {:ok, bytes, %{"package" => %{"name" => "jason"}}} = ResultJson.read(path)
    assert bytes == ~s({"package":{"name":"jason"}})
  end

  test "a missing file is unreadable" do
    assert {:error, :unreadable} = ResultJson.read("/nonexistent/path/result.json")
  end

  test "a symlink is refused rather than followed" do
    dir = Path.join(System.tmp_dir!(), "result-json-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    target = Path.join(dir, "secret.json")
    File.write!(target, ~s({"ok":true}))
    link = Path.join(dir, "result.json")
    File.ln_s!(target, link)
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:error, :unreadable} = ResultJson.read(link)
  end

  test "a file right at the cap is read; one byte over is refused" do
    # Padding inside a JSON string keeps the document valid at any length.
    pad = fn n -> ~s({"pad":") <> String.duplicate("a", n) <> ~s("}) end
    exact = pad.(10)
    max = byte_size(exact)

    path = write("result.json", exact)
    assert {:ok, ^exact, %{"pad" => _}} = ResultJson.read(path, max)

    over = pad.(11)
    path2 = write("result.json", over)
    assert {:error, :too_large} = ResultJson.read(path2, max)
  end

  test "malformed JSON is unparsable" do
    path = write("result.json", "{nope")
    assert {:error, :unparsable} = ResultJson.read(path)
  end

  test "nesting at the bound is accepted; one level deeper is refused" do
    at_bound = write("result.json", deeply_nested(64))
    assert {:ok, _bytes, _decoded} = ResultJson.read(at_bound, 8_388_608, 64)

    one_deeper = write("result.json", deeply_nested(65))
    assert {:error, :too_deep} = ResultJson.read(one_deeper, 8_388_608, 64)
  end

  test "a wide but shallow document is unaffected by the depth bound" do
    wide = ~s({"systems":) <> Jason.encode!(for i <- 1..500, do: %{"n" => i}) <> "}"
    path = write("result.json", wide)
    assert {:ok, _bytes, decoded} = ResultJson.read(path, 8_388_608, 8)
    assert length(decoded["systems"]) == 500
  end
end
