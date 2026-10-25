defmodule Portal.BuilderArgvParityTest do
  @moduledoc """
  `Compatibility.Builder.Argv` is what the remote agent runs; `Portal.Builder`
  is what the local host runs. They must agree flag for flag, or a remote
  builder would run something a local host does not. When the isolation branch
  changes `Portal.Builder.build_docker_args/4`, this test is what forces it
  to switch over to `Argv.build/1` (with `nerves_cache_mode: :readonly` and
  `hardening: true`) rather than drift.
  """
  use ExUnit.Case, async: false

  alias Compatibility.Builder.Argv
  alias Portal.Builder

  setup do
    previous = Application.get_env(:portal, Portal.Builder, [])
    on_exit(fn -> Application.put_env(:portal, Portal.Builder, previous) end)
    %{previous: previous}
  end

  defp put_builder(overrides, previous),
    do: Application.put_env(:portal, Portal.Builder, Keyword.merge(previous, overrides))

  defp job,
    do: %{run_id: "jason-1.4.4-1", image_name: "ncc-worker:local", image_digest: "sha256:abc"}

  # `Portal.Builder` derives the /tmp and ~/.cache scratch binds from the
  # scratch dir above `work_dir`, so the spec names them explicitly.
  defp spec do
    %{
      run_id: "jason-1.4.4-1",
      image: "ncc-worker:local",
      user: "0:0",
      work_dir: "/s/work",
      output_dir: "/s/out",
      files_dir: "/s/files",
      tmp_dir: "/s/tmp",
      cache_dir: "/s/cache",
      nerves_cache: Builder.nerves_cache(),
      hex_cache: Builder.hex_cache(),
      build_cache: nil,
      cpus: nil,
      memory: nil,
      build_concurrency: nil,
      nerves_cache_mode: :legacy,
      hardening: true
    }
  end

  test "the two builders produce the same argv for a plain build", %{previous: previous} do
    put_builder(
      [run_as_user: "0:0", cpus: nil, memory: nil, build_concurrency: nil, build_cache: nil],
      previous
    )

    assert Builder.build_docker_args(job(), "/s/work", "/s/out", "/s/files") == Argv.build(spec())
  end

  test "and for a capped build with concurrency", %{previous: previous} do
    put_builder(
      [run_as_user: "0:0", cpus: "2", memory: "4g", build_concurrency: "2", build_cache: nil],
      previous
    )

    assert Builder.build_docker_args(job(), "/s/work", "/s/out", "/s/files") ==
             Argv.build(Map.merge(spec(), %{cpus: "2", memory: "4g", build_concurrency: "2"}))
  end

  test "and with a build cache, which is read-only on both sides", %{previous: previous} do
    root = Path.join(System.tmp_dir!(), "parity-cache-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    put_builder(
      [run_as_user: "0:0", cpus: nil, memory: nil, build_concurrency: nil, build_cache: root],
      previous
    )

    slug = Builder.build_cache_slug_dir("sha256:abc")

    assert Builder.build_docker_args(job(), "/s/work", "/s/out", "/s/files") ==
             Argv.build(Map.put(spec(), :build_cache, slug))
  end
end
