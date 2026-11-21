defmodule Portal.BuilderJudgeInputTest do
  # Not async: swaps the `Portal.Builder` application env. A data case: the
  # judge options read the `foreign_priv_enabled` setting.
  use Portal.DataCase, async: false

  alias Portal.Builder

  setup do
    previous = Application.get_env(:portal, Builder, [])
    on_exit(fn -> Application.put_env(:portal, Builder, previous) end)
    %{previous: previous}
  end

  @job %{
    run_id: "r1",
    image_name: "ncc-worker",
    image_digest: "sha256:x",
    package: %{"name" => "jason", "version" => "1.4.4", "source" => "hex"},
    systems_filter: nil,
    mode: "toolchain"
  }

  test "off by default: no judge options for any build", %{previous: previous} do
    Application.put_env(
      :portal,
      Builder,
      Keyword.drop(previous, [:judge_makefile_rule2, :judge_native_side])
    )

    for mode <- ["toolchain", nil, "argus_only", "warm_nerves"],
        do: assert(Builder.judge_input(mode) == nil, inspect(mode))
  end

  test "on: toolchain builds only", %{previous: previous} do
    Application.put_env(:portal, Builder, Keyword.put(previous, :judge_makefile_rule2, true))
    assert Builder.judge_input("toolchain") == %{"makefile_rule2" => true}

    for mode <- [nil, "argus_only", "warm_nerves"],
        do: assert(Builder.judge_input(mode) == nil, inspect(mode))
  end

  # Foreign priv spec 3.1, gate 1: the flag goes to toolchain builds (pinned
  # toolchain builds are `mode: "toolchain"` too) while the setting is on,
  # never from a host env var.
  test "foreign_priv: toolchain builds only, and only with the setting on", %{previous: previous} do
    Application.put_env(:portal, Builder, Keyword.delete(previous, :judge_makefile_rule2))
    {:ok, _} = Portal.Settings.save(%{foreign_priv_enabled: false})
    assert Builder.judge_input("toolchain") == nil

    {:ok, _} = Portal.Settings.save(%{foreign_priv_enabled: true})
    assert Builder.judge_input("toolchain") == %{"foreign_priv" => true}

    for mode <- [nil, "argus_only", "warm_nerves", "host_native"],
        do: assert(Builder.judge_input(mode) == nil, inspect(mode))

    Application.put_env(:portal, Builder, Keyword.put(previous, :judge_makefile_rule2, true))

    assert Builder.judge_input("toolchain") == %{
             "foreign_priv" => true,
             "makefile_rule2" => true
           }
  end

  # S3 native side: `NCC_JUDGE_NATIVE_SIDE=1` (`:judge_native_side`) puts
  # the flag into toolchain builds only, next to the others.
  test "native_side: toolchain builds only, while the config says so", %{previous: previous} do
    base = Keyword.drop(previous, [:judge_makefile_rule2, :judge_native_side])
    Application.put_env(:portal, Builder, base)
    {:ok, _} = Portal.Settings.save(%{foreign_priv_enabled: false})
    assert Builder.judge_input("toolchain") == nil

    Application.put_env(:portal, Builder, Keyword.put(base, :judge_native_side, true))
    assert Builder.judge_input("toolchain") == %{"native_side" => true}

    for mode <- [nil, "argus_only", "warm_nerves", "host_native"],
        do: assert(Builder.judge_input(mode) == nil, inspect(mode))

    for value <- [false, nil, "1"] do
      Application.put_env(:portal, Builder, Keyword.put(base, :judge_native_side, value))
      assert Builder.judge_input("toolchain") == nil, inspect(value)
    end

    Application.put_env(
      :portal,
      Builder,
      base |> Keyword.put(:judge_native_side, true) |> Keyword.put(:judge_makefile_rule2, true)
    )

    assert Builder.judge_input("toolchain") == %{"makefile_rule2" => true, "native_side" => true}
  end

  # S4: relocatable builds, a setting like foreign_priv's (turned on without
  # a deploy), for toolchain builds only.
  test "relocate: toolchain builds only, and only with the relocate_builds_enabled setting", %{
    previous: previous
  } do
    Application.put_env(
      :portal,
      Builder,
      Keyword.drop(previous, [:judge_makefile_rule2, :judge_native_side])
    )

    {:ok, _} =
      Portal.Settings.save(%{foreign_priv_enabled: false, relocate_builds_enabled: false})

    assert Builder.judge_input("toolchain") == nil

    {:ok, _} = Portal.Settings.save(%{relocate_builds_enabled: true})
    assert Builder.judge_input("toolchain") == %{"relocate" => true}

    for mode <- [nil, "argus_only", "warm_nerves", "host_native"],
        do: assert(Builder.judge_input(mode) == nil, inspect(mode))
  end

  # The umbrella re-review's T2: a pinned build that held would be thrown
  # away at ingest (`@pinned_relocated`), so it is never sent relocate and
  # skips the two extra compiles.
  test "a pinned toolchain job is never sent relocate", %{previous: previous} do
    Application.put_env(
      :portal,
      Builder,
      Keyword.drop(previous, [:judge_makefile_rule2, :judge_native_side])
    )

    {:ok, _} =
      Portal.Settings.save(%{foreign_priv_enabled: true, relocate_builds_enabled: true})

    assert Builder.judge_input("toolchain", %{}) == %{"foreign_priv" => true, "relocate" => true}

    assert Builder.judge_input("toolchain", %{pins: %{"decimal" => "2.1.1"}}) == %{
             "foreign_priv" => true
           }

    {:ok, _} = Portal.Settings.save(%{foreign_priv_enabled: false})
    assert Builder.judge_input("toolchain", %{pins: %{"decimal" => "2.1.1"}}) == nil
  end

  # The umbrella re-review's T1: the two binds need their mount points in
  # the image (`ncc.relocate=1`, as `/hex-cache` needs `ncc.hex-cache`). A
  # job on an older image builds without relocation, setting or not: no
  # `relocate` in its input and no bind.
  describe "the relocate image label" do
    @relocating %{
      run_id: "r-label",
      image_name: "ncc-worker:local",
      image_digest: "sha256:x",
      mode: "toolchain",
      systems_filter: nil,
      judge: %{"relocate" => true, "foreign_priv" => true},
      memory: "4g",
      hex_cache_mode: :readonly
    }

    defp label!(previous, label) do
      parent = self()

      Application.put_env(
        :portal,
        Builder,
        Keyword.put(previous, :relocate_image_label, fn ref ->
          send(parent, {:inspected, ref})
          label
        end)
      )
    end

    defp args(job),
      do: Builder.build_docker_args(job, "/scratch/work", "/scratch/out", "/scratch/files")

    test "a labelled image keeps relocate and gets both binds", %{previous: previous} do
      label!(previous, {:ok, "1"})
      job = Builder.gate_relocation(@relocating)
      assert_received {:inspected, "ncc-worker:local"}
      assert job.judge == %{"relocate" => true, "foreign_priv" => true}
      assert Builder.worker_input(job)["judge"]["relocate"] == true
      assert "type=bind,source=/scratch/users,target=/Users" in args(job)
      assert "type=bind,source=/scratch/relocate-home,target=/home/ncc-relocate" in args(job)
    end

    test "an older image, or one docker cannot inspect, builds without relocation", %{
      previous: previous
    } do
      for label <- [{:ok, nil}, {:ok, ""}, {:ok, "0"}, :error] do
        label!(previous, label)
        job = Builder.gate_relocation(@relocating)
        assert job.judge == %{"foreign_priv" => true}, inspect(label)
        refute Map.has_key?(Builder.worker_input(job)["judge"], "relocate")
        refute Enum.any?(args(job), &String.contains?(&1, "/Users")), inspect(label)
        refute Enum.any?(args(job), &String.contains?(&1, "ncc-relocate")), inspect(label)
      end

      label!(previous, {:ok, nil})
      only = Builder.gate_relocation(%{@relocating | judge: %{"relocate" => true}})
      assert only.judge == nil
    end

    test "a job not sent relocate is not inspected", %{previous: previous} do
      label!(previous, {:ok, nil})
      job = %{@relocating | judge: %{"foreign_priv" => true}}
      assert Builder.gate_relocation(job) == job
      assert Builder.gate_relocation(%{job | judge: nil}) == %{job | judge: nil}
      refute_received {:inspected, _}
    end
  end

  # A toolchain job that may relocate gets its two scratch dirs, at
  # /home/ncc-relocate and /Users; no other.
  test "a job sent relocate gets /home/ncc-relocate and /Users mounts of its own scratch" do
    job = %{
      run_id: "r-users",
      image_name: "ncc-worker:local",
      image_digest: "sha256:x",
      mode: "toolchain",
      judge: %{"relocate" => true},
      memory: "4g",
      hex_cache_mode: :readonly
    }

    argv = Builder.build_docker_args(job, "/scratch/work", "/scratch/out", "/scratch/files")
    assert "type=bind,source=/scratch/users,target=/Users" in argv
    assert "type=bind,source=/scratch/relocate-home,target=/home/ncc-relocate" in argv

    plain =
      Builder.build_docker_args(
        %{job | judge: nil},
        "/scratch/work",
        "/scratch/out",
        "/scratch/files"
      )

    refute Enum.any?(plain, &String.contains?(&1, "/Users"))
    refute Enum.any?(plain, &String.contains?(&1, "ncc-relocate"))
  end

  # Differential builds (`NccWorker.Portability.Differential`): toolchain
  # builds only, while `NCC_JUDGE_DIFFERENTIAL=1` (`:judge_differential`).
  test "differential: toolchain builds only, and only with the flag on", %{previous: previous} do
    base =
      Keyword.drop(previous, [:judge_makefile_rule2, :judge_native_side, :judge_differential])

    Application.put_env(:portal, Builder, base)
    {:ok, _} = Portal.Settings.save(%{foreign_priv_enabled: false})
    assert Builder.judge_input("toolchain") == nil

    Application.put_env(:portal, Builder, Keyword.put(base, :judge_differential, true))
    assert Builder.judge_input("toolchain") == %{"differential" => true}

    for mode <- [nil, "argus_only", "warm_nerves", "host_native"],
        do: assert(Builder.judge_input(mode) == nil, inspect(mode))

    for value <- [false, nil, "1"] do
      Application.put_env(:portal, Builder, Keyword.put(base, :judge_differential, value))
      assert Builder.judge_input("toolchain") == nil, inspect(value)
    end
  end

  test "worker_input carries judge only when set" do
    input = Builder.worker_input(Map.put(@job, :judge, %{"makefile_rule2" => true}))
    assert input["judge"] == %{"makefile_rule2" => true}
    refute Map.has_key?(Builder.worker_input(@job), "judge")
  end
end
