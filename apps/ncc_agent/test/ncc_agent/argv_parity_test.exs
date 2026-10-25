defmodule NccAgent.ArgvParityTest do
  @moduledoc """
  The argv the agent runs is the post-isolation argv of the sandbox design:
  read-only Nerves cache at /nerves-cache, read-only root with the scratch
  binds, pids limit. When `Portal.Builder` switches to
  `Compatibility.Builder.Argv` with the same options (feat/sandbox-isolation),
  this fixture and `Portal.BuilderArgvParityTest` describe the same argv.
  """
  use ExUnit.Case, async: true

  alias NccAgent.{Config, Job}

  @fixture Path.expand("../fixtures/post_isolation_argv.txt", __DIR__)

  test "the agent's argv equals the post-isolation fixture" do
    config = %{
      Config.defaults()
      | portal_url: "https://x",
        data_dir: "/srv/ncc",
        build_user: "1001:1001",
        cpus: "4",
        memory: "8g"
    }

    claim = %{
      "run_id" => "rb-jason-1.4.4-1700000000000",
      "image" => %{
        "name" => "ghcr.io/tomhoenderdos/ncc-worker",
        "digest" => "sha256:" <> String.duplicate("a", 64)
      }
    }

    scratch = "/srv/ncc/scratch/rb-jason-1.4.4-1700000000000"

    dirs = %{
      work: "#{scratch}/work",
      out: "#{scratch}/out",
      files: "#{scratch}/files",
      tmp: "#{scratch}/tmp",
      cache: "#{scratch}/cache"
    }

    env = [
      {"NERVES_ARTIFACTS_DIR", "/work/nerves/artifacts"},
      {"NERVES_DL_DIR", "/work/nerves/dl"}
    ]

    argv = config |> Job.argv_spec(claim, dirs, env) |> Compatibility.Builder.Argv.build()
    expected = @fixture |> File.read!() |> String.split("\n", trim: true)

    assert argv == expected
    refute Enum.any?(argv, &String.contains?(&1, "/build-cache"))
    refute Enum.any?(argv, &String.contains?(&1, "/home/nerves/.nerves"))
  end
end
