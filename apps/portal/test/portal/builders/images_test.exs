defmodule Portal.Builders.ImagesTest do
  use ExUnit.Case, async: false

  alias Portal.Builders.Images

  setup do
    path = Path.join(System.tmp_dir!(), "images-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:portal, Images, [])
    Application.put_env(:portal, Images, Keyword.put(previous, :path, path))

    on_exit(fn ->
      Application.put_env(:portal, Images, previous)
      File.rm(path)
    end)

    %{path: path}
  end

  @doc_json """
  {"commit": "abc", "generated_at": "2026-10-25T20:00:00Z",
   "images": {"ncc-worker": {"name": "ghcr.io/tomhoenderdos/ncc-worker", "tag": "abc",
                             "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}},
   "agent": {"version": "1761400000.abcdefabcdef",
             "releases": {"x86_64": {"url": "https://example.com/a.tar.gz",
                                     "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
                          "aarch64": {"url": "http://example.com/b.tar.gz",
                                      "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
                          "riscv64": {"url": "https://example.com/c.tar.gz", "sha256": "cc"}}}}
  """

  test "reads the worker image and the agent release", %{path: path} do
    File.write!(path, @doc_json)

    assert %{name: "ghcr.io/tomhoenderdos/ncc-worker", digest: "sha256:" <> _, tag: "abc"} =
             Images.worker_image()

    # The agent downloads and runs these: only https URLs with a full sha256
    # get through (the http one and the short digest are dropped).
    assert %{version: "1761400000.abcdefabcdef", releases: releases} = Images.agent()
    assert Map.keys(releases) == ["x86_64"]
    assert releases["x86_64"].sha256 == String.duplicate("a", 64)

    assert Images.min_agent_version() == "1761400000.abcdefabcdef"
  end

  test "a missing or invalid file is nil, never a crash", %{path: path} do
    assert Images.worker_image() == nil
    assert Images.agent() == nil
    assert {:error, :missing} = Images.load()

    File.write!(path, "{not json")
    assert {:error, :invalid} = Images.load()
    assert Images.worker_image() == nil
  end

  # No path ships in the repository: a node without NCC_IMAGES_JSON has no
  # registry image, so Routing keeps every build local.
  test "an unset path is a missing file, never a crash" do
    Application.put_env(:portal, Images, path: nil)
    assert Images.path() == nil
    assert {:error, :missing} = Images.load()
    assert Images.worker_image() == nil
    assert Images.agent() == nil

    Application.put_env(:portal, Images, [])
    assert {:error, :missing} = Images.load()
  end

  test "a digest that is not sha256:<64 hex> is refused", %{path: path} do
    File.write!(path, String.replace(@doc_json, ~r/sha256:1+/, "sha256:zz"))
    assert Images.worker_image() == nil
  end
end
