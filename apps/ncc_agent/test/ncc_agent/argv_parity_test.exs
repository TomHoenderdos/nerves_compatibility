defmodule NccAgent.ArgvParityTest do
  @moduledoc """
  The agent runs `Compatibility.Builder.Argv.build/1` on a spec of its own
  making. This pins that its config and scratch layout resolve to the shared
  post-isolation fixture `Compatibility.Builder.ArgvTest` and
  `Portal.BuilderTest` are pinned to, minus the one thing a remote builder
  never has: a build cache. A remote build therefore runs exactly what the
  local host runs.
  """
  use ExUnit.Case, async: true

  alias Compatibility.Builder.Argv
  alias NccAgent.{Config, Job}

  @fixture Path.expand(
             "../../../compatibility/test/fixtures/argv/post_isolation.exs",
             __DIR__
           )

  setup_all do
    {fixture, _binding} = Code.eval_file(@fixture)
    fixture
  end

  # The fixture's cache paths are `/srv/ncc/...`, the agent's default data
  # dir, so `Config.path/2` resolves to them without any special casing.
  defp config(input) do
    %{
      Config.defaults()
      | portal_url: "https://x",
        data_dir: "/srv/ncc",
        build_user: input.user,
        cpus: input.cpus,
        memory: input.memory,
        build_concurrency: input.build_concurrency
    }
  end

  defp claim(input, image) do
    %{
      "run_id" => String.replace_prefix(input.container_name, "ncc-", ""),
      "image" => %{"name" => image, "digest" => "sha256:" <> String.duplicate("a", 64)}
    }
  end

  # Drops `value` and the flag before it (`--mount x`, `-e x`).
  defp drop_pair(argv, value) do
    index = Enum.find_index(argv, &(&1 == value)) || flunk("the fixture lacks #{value}")
    argv |> List.delete_at(index) |> List.delete_at(index - 1)
  end

  test "the agent's argv is the shared fixture's without the build cache", %{
    input: input,
    argv: argv
  } do
    config = config(input)
    assert Config.path(config, :nerves_cache) == input.paths.nerves_cache
    assert Config.path(config, :hex_cache) == input.paths.hex_cache

    expected =
      argv
      |> drop_pair("type=bind,source=#{input.paths.build_cache},target=/build-cache,readonly")
      |> drop_pair("NCC_BUILD_CACHE=/build-cache")

    dirs = Map.take(input.paths, [:work, :out, :files, :tmp, :cache])
    spec = Job.argv_spec(config, claim(input, input.image), dirs)

    assert Argv.build(spec) == expected
    refute Enum.any?(expected, &String.contains?(&1, "build-cache"))
    refute Enum.any?(expected, &String.contains?(&1, "/home/nerves/.nerves"))
  end

  test "the agent's runtime reaches the argv", %{input: input} do
    dirs = Map.take(input.paths, [:work, :out, :files, :tmp, :cache])
    config = %{config(input) | docker_runtime: "runsc"}
    argv = config |> Job.argv_spec(claim(input, input.image), dirs) |> Argv.build()

    assert "--runtime=runsc" in argv
  end

  test "a registry image is run by digest", %{input: input} do
    dirs = Map.take(input.paths, [:work, :out, :files, :tmp, :cache])
    claim = claim(input, "ghcr.io/tomhoenderdos/ncc-worker")
    argv = input |> config() |> Job.argv_spec(claim, dirs) |> Argv.build()

    assert List.last(argv) ==
             "ghcr.io/tomhoenderdos/ncc-worker@sha256:" <> String.duplicate("a", 64)
  end
end
