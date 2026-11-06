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

  @amd "sha256:" <> String.duplicate("1", 64)
  @arm "sha256:" <> String.duplicate("2", 64)
  @index "sha256:" <> String.duplicate("3", 64)

  defp write_worker!(path, worker) do
    File.write!(path, Jason.encode!(%{"commit" => "abc", "images" => %{"ncc-worker" => worker}}))
  end

  test "an images.json from before multi-arch images is the x86_64 digest alone", %{path: path} do
    File.write!(path, @doc_json)

    assert %{digest: @amd, index: nil, platforms: platforms} = image = Images.worker_image()
    assert platforms == %{"x86_64" => @amd}
    assert Images.platform_digest(image, "x86_64") == @amd
    assert Images.platform_digest(image, "aarch64") == nil
  end

  test "reads one platform digest per architecture beside the index", %{path: path} do
    write_worker!(path, %{
      "name" => "ghcr.io/tomhoenderdos/ncc-worker",
      "tag" => "abc",
      "digest" => @amd,
      "index" => @index,
      "platforms" => %{"x86_64" => @amd, "aarch64" => @arm, "riscv64" => "sha256:zz"}
    })

    image = Images.worker_image()
    assert %{digest: @amd, index: @index} = image
    # A malformed platform digest never leaves this file.
    assert image.platforms == %{"x86_64" => @amd, "aarch64" => @arm}
    assert Images.platform_digest(image, "aarch64") == @arm
    assert Images.platform_digest(image, "riscv64") == nil
    assert Images.platform_digest(nil, "x86_64") == nil
  end

  # `digest` is what a portal from before multi-arch images reads as the one
  # image to run: it has to be the x86_64 platform's, or that portal would
  # hand x86_64 builders some other image.
  test "a top-level digest that is not the x86_64 platform's is refused", %{path: path} do
    write_worker!(path, %{
      "name" => "ghcr.io/tomhoenderdos/ncc-worker",
      "digest" => @index,
      "platforms" => %{"x86_64" => @amd, "aarch64" => @arm}
    })

    assert Images.worker_image() == nil
  end

  test "a malformed index is dropped, not trusted", %{path: path} do
    write_worker!(path, %{
      "name" => "ghcr.io/tomhoenderdos/ncc-worker",
      "digest" => @amd,
      "index" => "latest",
      "platforms" => %{"x86_64" => @amd}
    })

    assert %{index: nil} = Images.worker_image()
  end

  test "a digest that is not sha256:<64 hex> is refused", %{path: path} do
    File.write!(path, String.replace(@doc_json, ~r/sha256:1+/, "sha256:zz"))
    assert Images.worker_image() == nil
  end
end
