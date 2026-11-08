defmodule Portal.Workers.IngestIdentityTest do
  # An ingest job records what the job it was enqueued for asked to build:
  # its package and version, and for a toolchain build its toolchain. The
  # build's result.json has to agree with that before anything is recorded or
  # published, and the job's identity, not the result's, is what the rows are
  # written under.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import ExUnit.CaptureLog

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{ArtifactMembership, Package, Run, ToolchainBuild}
  alias Portal.Workers.{Build, Ingest}

  # Replays the build the test put in the process dictionary, as the scratch
  # dir would.
  defmodule StubBuilder do
    def build(_args, _opts \\ []), do: Process.get(:identity_build_response)
    def cleanup(run_id), do: send(self(), {:cleanup, run_id}) && :ok
    def image_digest(_image), do: "sha256:identity"
    def docker_image, do: "ncc-worker:local"

    def load_run(_run_id) do
      case Process.get(:identity_build) do
        nil -> {:error, :missing_result_json}
        build -> {:ok, build}
      end
    end
  end

  defmodule StubVersions do
    def latest_version(_package), do: {:ok, "1.0.0"}
  end

  setup do
    Application.put_env(:portal, :build_runner, StubBuilder)
    Application.put_env(:portal, :package_version_resolver, StubVersions)

    on_exit(fn ->
      Application.delete_env(:portal, :build_runner)
      Application.delete_env(:portal, :package_version_resolver)
    end)

    :ok
  end

  defp sha(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp unique(prefix),
    do:
      "#{prefix}_#{System.unique_integer([:positive])}_#{Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)}"

  defp files_dir_with(contents) do
    dir = Path.join(System.tmp_dir!(), "identity-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(contents, &File.write!(Path.join(dir, sha(&1)), &1))
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp entry(path, content),
    do: %{
      "path" => path,
      "sha256" => sha(content),
      "size" => byte_size(content),
      "mode" => 33_188
    }

  # A full run's result.json for `name` `version`, publishing one host beam.
  defp run_result(name, version, beam) do
    %{
      "package" => %{"name" => name, "version" => version},
      "finished_at" => "2026-11-05T10:00:00Z",
      "scope" => "full",
      "systems" => %{
        "host" => %{
          "status" => "pass",
          "beam_scan" => %{
            "footprint" => %{"file_manifest" => %{"ebin" => [entry("ebin/#{name}.beam", beam)]}}
          }
        }
      }
    }
  end

  defp toolchain_result(name, version, beam, opts \\ []) do
    %{
      "scope" => "toolchain",
      "finished_at" => "2026-11-05T10:00:00Z",
      "package" => %{"name" => name, "version" => version},
      "systems" => %{},
      "toolchain_build" => %{
        "status" => "pass",
        "reason" => nil,
        "elixir" => Keyword.get(opts, :elixir, "1.19.1"),
        "otp" => Keyword.get(opts, :otp, "28"),
        "deps_lock" => %{},
        "package_checksum" => "outer",
        "compile_env" => [],
        "file_manifest" => %{"ebin" => [entry("ebin/#{name}.beam", beam)], "priv" => []}
      }
    }
  end

  defp replay(result, files_dir) do
    Process.put(:identity_build, %{
      exit_code: 0,
      result: result,
      files_dir: files_dir,
      output_dir: files_dir,
      log: "runner log"
    })
  end

  defp runs_of(name),
    do: Run |> Ash.Query.filter(package.name == ^name) |> Ash.read!(domain: Catalog)

  defp toolchain_rows_of(name),
    do: ToolchainBuild |> Ash.Query.filter(package.name == ^name) |> Ash.read!(domain: Catalog)

  defp membership?(content) do
    ArtifactMembership
    |> Ash.Query.filter(sha256 == ^sha(content))
    |> Ash.exists?(domain: Catalog)
  end

  defp package?(name),
    do: Package |> Ash.Query.filter(name == ^name) |> Ash.exists?(domain: Catalog)

  defp ingest(args) do
    Ingest.perform(%Oban.Job{args: args, attempt: 1, max_attempts: 5})
  end

  describe "the jobs that enqueue an ingest" do
    test "a build hands its package and version to the ingest" do
      Process.put(
        :identity_build_response,
        {:ok, %{exit_code: 0, result: %{}, files_dir: "/f", output_dir: "/o", log: ""}}
      )

      assert :ok =
               perform_job(Build, %{
                 "package" => "jason",
                 "version" => "1.4.4",
                 "image_digest" => "sha256:identity"
               })

      assert [job] = all_enqueued(worker: Ingest)
      assert %{"package" => "jason", "version" => "1.4.4"} = job.args
      # The image ran on this host, so the run is this host's architecture.
      assert job.args["arch"] == Compatibility.Arch.current()
    end

    test "a toolchain build hands its package, version and toolchain to the ingest" do
      Process.put(
        :identity_build_response,
        {:ok,
         %{
           exit_code: 0,
           result: %{"toolchain_build" => %{"status" => "pass"}},
           files_dir: "/f",
           output_dir: "/o",
           log: ""
         }}
      )

      assert :ok =
               perform_job(Portal.Workers.ToolchainBuild, %{
                 "package" => "jason",
                 "version" => "1.4.4",
                 "toolchain" => "1.19/28",
                 "image" => "ncc-worker:elixir-1.19-otp-28",
                 "builder_version" => 1
               })

      assert [job] = all_enqueued(worker: Ingest)

      assert %{"package" => "jason", "version" => "1.4.4", "toolchain" => "1.19/28"} =
               job.args
    end
  end

  describe "a local run's ingest" do
    defp run_args(name, version) do
      %{
        "run_id" => "run-#{name}",
        "image_digest" => "sha256:identity",
        "package" => name,
        "version" => version
      }
    end

    test "records a result that matches its job, under the job's identity" do
      name = unique("idok")
      beam = "beam-#{name}"
      replay(run_result(name, "1.0.0", beam), files_dir_with([beam]))

      assert :ok = ingest(run_args(name, "1.0.0"))
      assert [%{version_tested: "1.0.0"}] = runs_of(name)
    end

    test "records the architecture the build ran on" do
      name = unique("idarch")
      beam = "beam-#{name}"
      replay(run_result(name, "1.0.0", beam), files_dir_with([beam]))

      assert :ok = ingest(Map.put(run_args(name, "1.0.0"), "arch", "aarch64"))
      assert [%{arch: "aarch64"}] = runs_of(name)
    end

    # An ingest queued before runs recorded it ran on this node, as its build did.
    test "a local ingest that names no architecture records this host's" do
      name = unique("idhost")
      beam = "beam-#{name}"
      replay(run_result(name, "1.0.0", beam), files_dir_with([beam]))

      assert :ok = ingest(run_args(name, "1.0.0"))
      assert [%{arch: arch}] = runs_of(name)
      assert arch == Compatibility.Arch.current()
    end

    test "refuses a result for another package, and records nothing" do
      wanted = unique("idwanted")
      other = unique("idother")
      beam = "beam-#{other}"
      replay(run_result(other, "1.0.0", beam), files_dir_with([beam]))

      log = capture_log(fn -> refute ingest(run_args(wanted, "1.0.0")) == :ok end)

      assert runs_of(wanted) == []
      assert runs_of(other) == []
      refute package?(other)
      refute membership?(beam)
      assert log =~ wanted
      assert log =~ other
    end

    test "refuses a result for another version, and records nothing" do
      name = unique("idver")
      beam = "beam-#{name}"
      replay(run_result(name, "9.9.9", beam), files_dir_with([beam]))

      log = capture_log(fn -> refute ingest(run_args(name, "1.0.0")) == :ok end)

      assert runs_of(name) == []
      refute membership?(beam)
      assert log =~ "1.0.0"
      assert log =~ "9.9.9"
    end

    # Queued before jobs carried an identity: nothing to check the result
    # against, so it is not taken on trust.
    test "refuses a job that does not say what it built" do
      name = unique("idold")
      beam = "beam-#{name}"
      replay(run_result(name, "1.0.0", beam), files_dir_with([beam]))

      capture_log(fn ->
        refute ingest(%{"run_id" => "run-#{name}", "image_digest" => "sha256:identity"}) == :ok
      end)

      assert runs_of(name) == []
      refute membership?(beam)
    end
  end

  describe "a toolchain build's ingest" do
    defp toolchain_args(name, version, toolchain \\ "1.19/28") do
      %{
        "run_id" => "tc-#{name}",
        "image_digest" => "sha256:identity",
        "kind" => "toolchain",
        "package" => name,
        "version" => version,
        "toolchain" => toolchain,
        "builder_version" => 1
      }
    end

    test "records a result that matches its job" do
      name = unique("tcok")
      beam = "beam-#{name}"
      replay(toolchain_result(name, "1.0.0", beam), files_dir_with([beam]))

      assert :ok = ingest(toolchain_args(name, "1.0.0"))
      assert [%{version: "1.0.0", toolchain: "1.19/28", status: :pass}] = toolchain_rows_of(name)
    end

    test "refuses a result for another package, and publishes nothing" do
      wanted = unique("tcwanted")
      other = unique("tcother")
      beam = "beam-#{other}"
      replay(toolchain_result(other, "1.0.0", beam), files_dir_with([beam]))

      log = capture_log(fn -> refute ingest(toolchain_args(wanted, "1.0.0")) == :ok end)

      assert toolchain_rows_of(wanted) == []
      assert toolchain_rows_of(other) == []
      refute package?(other)
      refute membership?(beam)
      assert log =~ wanted
      assert log =~ other
    end

    test "refuses a result for another version, and publishes nothing" do
      name = unique("tcver")
      beam = "beam-#{name}"
      replay(toolchain_result(name, "9.9.9", beam), files_dir_with([beam]))

      capture_log(fn -> refute ingest(toolchain_args(name, "1.0.0")) == :ok end)

      assert toolchain_rows_of(name) == []
      refute membership?(beam)
    end

    # Built on another Elixir minor or OTP major than the job asked for: the
    # files would be served to clients of the wrong toolchain.
    test "refuses a result built on another toolchain, and publishes nothing" do
      name = unique("tctc")
      beam = "beam-#{name}"

      replay(
        toolchain_result(name, "1.0.0", beam, elixir: "1.20.0", otp: "29"),
        files_dir_with([beam])
      )

      capture_log(fn -> refute ingest(toolchain_args(name, "1.0.0", "1.19/28")) == :ok end)

      assert toolchain_rows_of(name) == []
      refute membership?(beam)
    end

    test "refuses a job that does not say which package it built" do
      name = unique("tcold")
      beam = "beam-#{name}"
      replay(toolchain_result(name, "1.0.0", beam), files_dir_with([beam]))

      capture_log(fn ->
        refute ingest(Map.delete(toolchain_args(name, "1.0.0"), "package")) == :ok
      end)

      assert toolchain_rows_of(name) == []
      refute membership?(beam)
    end
  end

  # A toolchain build is made with and without the package's optional
  # dependencies, and a client is served the one that matches its own lock.
  # The variant is part of what the job asked to build: a result for the
  # other variant would publish files built against another dependency set.
  describe "a toolchain build's variant" do
    defp variant_args(name, variant) do
      base = %{
        "run_id" => "tc-#{name}",
        "image_digest" => "sha256:identity",
        "kind" => "toolchain",
        "package" => name,
        "version" => "1.0.0",
        "toolchain" => "1.19/28",
        "builder_version" => 1
      }

      if variant, do: Map.put(base, "variant", variant), else: base
    end

    # What the worker reports for a build asked to `request` the optional
    # dependencies: it echoes the request, and a build asked to exclude them
    # never starts the optional pass.
    defp variant_result(name, beam, request) do
      reason = if request == "exclude", do: "not_requested", else: nil

      name
      |> toolchain_result("1.0.0", beam)
      |> Map.put("requested_optional_deps", request)
      |> Map.put("optional_deps", %{
        "added" => [],
        "dropped" => [],
        "skipped" => [],
        "reason" => reason
      })
    end

    test "the toolchain build hands its variant to the ingest" do
      Process.put(
        :identity_build_response,
        {:ok,
         %{
           exit_code: 0,
           result: %{"toolchain_build" => %{"status" => "pass"}},
           files_dir: "/f",
           output_dir: "/o",
           log: ""
         }}
      )

      assert :ok =
               perform_job(Portal.Workers.ToolchainBuild, %{
                 "package" => "jason",
                 "version" => "1.4.4",
                 "toolchain" => "1.19/28",
                 "image" => "ncc-worker:elixir-1.19-otp-28",
                 "builder_version" => 1,
                 "variant" => "without"
               })

      assert [job] = all_enqueued(worker: Ingest)
      assert %{"package" => "jason", "variant" => "without"} = job.args
    end

    test "records a result for the job's variant under that variant" do
      name = unique("tcvarok")
      beam = "beam-#{name}"
      replay(variant_result(name, beam, "exclude"), files_dir_with([beam]))

      assert :ok = ingest(variant_args(name, "without"))
      assert [%{variant: :without, status: :pass}] = toolchain_rows_of(name)
      assert membership?(beam)
    end

    test "refuses a result built without for a with job, and publishes nothing" do
      name = unique("tcvarwith")
      beam = "beam-#{name}"
      replay(variant_result(name, beam, "exclude"), files_dir_with([beam]))

      log =
        capture_log(fn ->
          assert {:cancel, "ingest refused: " <> _} = ingest(variant_args(name, "with"))
        end)

      assert toolchain_rows_of(name) == []
      refute membership?(beam)
      assert log =~ "security:"
      assert log =~ ~r/:with\b/
      assert log =~ ":without"
    end

    test "refuses a result built with for a without job, and publishes nothing" do
      name = unique("tcvarwithout")
      beam = "beam-#{name}"
      replay(variant_result(name, beam, "include"), files_dir_with([beam]))

      log =
        capture_log(fn ->
          assert {:cancel, "ingest refused: " <> _} = ingest(variant_args(name, "without"))
        end)

      assert toolchain_rows_of(name) == []
      refute membership?(beam)
      assert log =~ ~r/:with\b/
      assert log =~ ":without"
    end

    # A result from a worker that does not echo the request still says when
    # it never started the optional pass: that is a build without them.
    test "refuses a result that skipped the optional pass for a with job" do
      name = unique("tcvarreason")
      beam = "beam-#{name}"

      replay(
        name |> variant_result(beam, "exclude") |> Map.delete("requested_optional_deps"),
        files_dir_with([beam])
      )

      capture_log(fn -> refute ingest(variant_args(name, "with")) == :ok end)

      assert toolchain_rows_of(name) == []
      refute membership?(beam)
    end

    # A worker image from before variants drops the `optional_deps` input key
    # and runs the optional pass anyway: its result echoes nothing and may
    # carry what it added. A without job takes only a result that says it was
    # built without them, so neither shape is stored under that identity.
    test "refuses a result that states no variant for a without job" do
      name = unique("tcvarsilent")
      beam = "beam-#{name}"

      replay(
        name
        |> variant_result(beam, "include")
        |> Map.delete("requested_optional_deps")
        |> Map.delete("optional_deps"),
        files_dir_with([beam])
      )

      log =
        capture_log(fn ->
          assert {:cancel, "ingest refused: " <> _} = ingest(variant_args(name, "without"))
        end)

      assert toolchain_rows_of(name) == []
      refute membership?(beam)
      assert log =~ "security:"
    end

    test "refuses a result that added optional dependencies for a without job" do
      name = unique("tcvaradded")
      beam = "beam-#{name}"

      silent =
        name
        |> variant_result(beam, "include")
        |> Map.delete("requested_optional_deps")
        |> put_in(["optional_deps", "added"], ["decimal"])

      replay(silent, files_dir_with([beam]))

      capture_log(fn ->
        assert {:cancel, "ingest refused: " <> _} = ingest(variant_args(name, "without"))
      end)

      assert toolchain_rows_of(name) == []
      refute membership?(beam)

      # Even under an explicit exclude echo, an added dependency means the
      # files were built against it.
      echoed = unique("tcvaraddedecho")
      echoed_beam = "beam-#{echoed}"

      replay(
        echoed
        |> variant_result(echoed_beam, "exclude")
        |> put_in(["optional_deps", "added"], ["decimal"]),
        files_dir_with([echoed_beam])
      )

      capture_log(fn ->
        assert {:cancel, "ingest refused: " <> _} = ingest(variant_args(echoed, "without"))
      end)

      assert toolchain_rows_of(echoed) == []
      refute membership?(echoed_beam)
    end

    # A worker that does not echo the request but reports it never started
    # the optional pass built without them.
    test "records a without result that only reports not_requested" do
      name = unique("tcvarnotreq")
      beam = "beam-#{name}"

      replay(
        name |> variant_result(beam, "exclude") |> Map.delete("requested_optional_deps"),
        files_dir_with([beam])
      )

      assert :ok = ingest(variant_args(name, "without"))
      assert [%{variant: :without, status: :pass}] = toolchain_rows_of(name)
      assert membership?(beam)
    end

    # Jobs queued before variants existed carry none, and were with builds.
    # The job's side decides: the result is held to a with build, never
    # taken for whatever variant it reports.
    test "a job without a variant is a with job" do
      ok = unique("tcvarnone")
      ok_beam = "beam-#{ok}"
      replay(variant_result(ok, ok_beam, "include"), files_dir_with([ok_beam]))

      assert :ok = ingest(variant_args(ok, nil))
      assert [%{variant: :with}] = toolchain_rows_of(ok)

      other = unique("tcvarnoneout")
      other_beam = "beam-#{other}"
      replay(variant_result(other, other_beam, "exclude"), files_dir_with([other_beam]))

      capture_log(fn -> refute ingest(variant_args(other, nil)) == :ok end)

      assert toolchain_rows_of(other) == []
      refute membership?(other_beam)
    end

    test "refuses a job whose variant is neither with nor without" do
      name = unique("tcvarbad")
      beam = "beam-#{name}"
      replay(variant_result(name, beam, "include"), files_dir_with([beam]))

      capture_log(fn -> refute ingest(variant_args(name, "maybe")) == :ok end)

      assert toolchain_rows_of(name) == []
      refute membership?(beam)
    end
  end

  # A config variant is part of what the job asked to build. The job's value
  # is the identity, never the result's echo; a job from before config
  # variants carries none and was a default build.
  describe "a toolchain build's config variant" do
    defp config_variant_args(name, config_variant) do
      base = %{
        "run_id" => "tc-#{name}",
        "image_digest" => "sha256:identity",
        "kind" => "toolchain",
        "package" => name,
        "version" => "1.0.0",
        "toolchain" => "1.19/28",
        "builder_version" => 1
      }

      if config_variant, do: Map.put(base, "config_variant", config_variant), else: base
    end

    # A marked build that recorded the phx_prod overlay key at its value.
    defp config_variant_result(name, beam, echo) do
      env = [
        %{
          "app" => "phoenix_live_view",
          "path" => ["root_tag_attribute"],
          "value" => Compatibility.ConfigVariants.encode("phx-r")
        }
      ]

      name
      |> toolchain_result("1.0.0", beam)
      |> update_in(["toolchain_build"], fn build ->
        build
        |> Map.merge(%{"compile_env" => env, "compile_env_rule" => 1})
        |> then(&if(echo, do: Map.put(&1, "config_variant", echo), else: &1))
      end)
    end

    setup do
      Portal.PrecompiledFixtures.drop_legacy_identity_index!()
      :ok
    end

    test "a named job's result is stored under the job's config variant" do
      name = unique("tccvnamed")
      beam = "beam-#{name}"
      replay(config_variant_result(name, beam, "phx_prod"), files_dir_with([beam]))

      assert :ok = ingest(config_variant_args(name, "phx_prod"))
      assert [%{config_variant: "phx_prod", status: :pass}] = toolchain_rows_of(name)
      assert membership?(beam)
    end

    test "a job without a config variant is a default job" do
      name = unique("tccvnone")
      beam = "beam-#{name}"
      replay(config_variant_result(name, beam, nil), files_dir_with([beam]))

      assert :ok = ingest(config_variant_args(name, nil))
      assert [%{config_variant: "default", status: :pass}] = toolchain_rows_of(name)

      # The result's echo does not make it a named build.
      other = unique("tccvnoneecho")
      other_beam = "beam-#{other}"
      replay(config_variant_result(other, other_beam, "phx_prod"), files_dir_with([other_beam]))

      log =
        capture_log(fn ->
          assert {:cancel, "ingest refused: " <> _} = ingest(config_variant_args(other, nil))
        end)

      assert toolchain_rows_of(other) == []
      refute membership?(other_beam)
      assert log =~ "security:"
      assert log =~ "phx_prod"
    end

    test "refuses a job whose config variant is not a known one, writing nothing" do
      name = unique("tccvbad")
      beam = "beam-#{name}"
      replay(config_variant_result(name, beam, "nope"), files_dir_with([beam]))

      capture_log(fn ->
        assert {:cancel, "ingest refused: " <> _} = ingest(config_variant_args(name, "nope"))
      end)

      assert toolchain_rows_of(name) == []
      refute membership?(beam)
      refute package?(name)
    end
  end
end
