defmodule Portal.Test.ArgusFixtures do
  @moduledoc "Ingests runs carrying argus results, for triage tests."

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Portal.Catalog.Ingestion

  def finding(extra \\ %{}) do
    Map.merge(
      %{
        "analysis" => "failure",
        "severity" => "warning",
        "title" => "Catch-all rescue swallows exceptions",
        "file" => "lib/p/a.ex",
        "line" => 10,
        "detail" => "P.A.run/1 takes every exception"
      },
      extra
    )
  end

  def ok(findings), do: %{"status" => "ok", "version" => "0.20.1", "findings" => findings}

  @doc "Ingests one run of `tripkg`. `n` orders runs: a higher `n` finishes later."
  def ingest(version, argus, n, package \\ "tripkg") do
    tag = "#{n}-#{System.unique_integer([:positive])}"
    files = Path.join(System.tmp_dir!(), "tri-f-#{tag}")
    out = Path.join(System.tmp_dir!(), "tri-o-#{tag}")
    File.mkdir_p!(files)
    File.mkdir_p!(Path.join(out, "logs"))

    on_exit(fn ->
      File.rm_rf(files)
      File.rm_rf(out)
    end)

    result =
      %{
        "package" => %{"name" => package, "version" => version},
        "systems" => %{"nerves_system_rpi4" => %{"status" => "pass"}}
      }
      |> then(&if(argus == :absent, do: &1, else: Map.put(&1, "argus", argus)))
      # `n: :unfinished` ingests a run with no finished_at, as a worker result
      # without one does.
      |> then(fn result ->
        if n == :unfinished,
          do: result,
          else:
            Map.put(
              result,
              "finished_at",
              DateTime.add(~U[2026-10-01 10:00:00Z], n, :hour) |> DateTime.to_iso8601()
            )
      end)

    {:ok, run} =
      Ingestion.ingest(result, %{
        run_id: "#{package}-#{tag}",
        image_digest: "sha256:x",
        files_dir: files,
        output_dir: out,
        log: "runner"
      })

    run
  end
end
