defmodule PortalWeb.PrecompiledReportClientE2ETest do
  @moduledoc """
  The precompiled client's `mix precompiled.report` against this endpoint,
  served on a loopback port: a child Mix project with the client as a path
  dependency, a fixture `report.json` and lock. Needs the client checkout in
  `PRECOMPILED_CLIENT_DIR`; excluded by default (tag `:e2e`).

      PRECOMPILED_CLIENT_DIR=../elixir_precompiled make test-report-e2e
  """
  use PortalWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Portal.{RateLimiter, Repo}

  @moduletag :e2e
  @moduletag timeout: 300_000
  @moduletag :tmp_dir

  # The child project's app name. `contact` is the one field the client
  # removes it from: the line for the `jason` package keeps its name.
  @app "jason"

  setup %{tmp_dir: dir} do
    client =
      System.get_env("PRECOMPILED_CLIENT_DIR") ||
        flunk("set PRECOMPILED_CLIENT_DIR to a precompiled checkout")

    RateLimiter.reset()
    on_exit(&RateLimiter.reset/0)

    server =
      start_supervised!(
        {Bandit,
         plug: PortalWeb.Endpoint, scheme: :http, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    File.mkdir_p!(Path.join(dir, "config"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule ReportE2E.MixProject do
      use Mix.Project
      def project, do: [app: :#{@app}, version: "0.1.0", deps: [{:precompiled, path: #{inspect(client)}}]]
    end
    """)

    File.write!(Path.join(dir, "config/config.exs"), """
    import Config
    config :precompiled, source: "http://127.0.0.1:#{port}/api/precompiled"
    """)

    sum = fn c -> String.duplicate(c, 64) end

    # The lock names packages the child's mix.exs does not depend on, on
    # purpose: the report command reads the lock as written and never
    # resolves it, and `mix deps.get` keeps unused entries. `acme_secret`
    # is a private-organisation package and must appear nowhere.
    File.write!(Path.join(dir, "mix.lock"), """
    %{
      "acme_secret": {:hex, :acme_secret, "0.1.0", "i", [:mix], [], "hexpm:acme", "#{sum.("f")}"},
      "jason": {:hex, :jason, "1.4.4", "i", [:mix], [{:decimal, "~> 2.0", [hex: :decimal, repo: "hexpm", optional: true]}], "hexpm", "#{sum.("a")}"},
      "decimal": {:hex, :decimal, "2.3.0", "i", [:mix], [], "hexpm", "#{sum.("b")}"},
    }
    """)

    {_, 0} =
      System.cmd("mix", ["deps.get"], cd: dir, stderr_to_stdout: true, env: child_env())

    %{dir: dir, port: port}
  end

  defp child_env do
    [
      {"MIX_ENV", "dev"},
      {"MIX_TARGET", nil},
      {"MIX_BUILD_ROOT", nil},
      {"MIX_BUILD_PATH", nil},
      {"MIX_DEPS_PATH", nil},
      {"MIX_TEST_PARTITION", nil},
      {"PRECOMPILED", nil}
    ]
  end

  defp write_report!(dir, context, lines) do
    report = Path.join(dir, "_build/dev/lib/.precompiled")
    File.mkdir_p!(report)

    File.write!(
      Path.join(report, "report.json"),
      Jason.encode!(%{
        "format" => 1,
        "built_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "context" =>
          Map.merge(
            %{
              "elixir" => "1.20.3",
              "otp" => "29",
              "target" => "host",
              "system" => nil,
              "system_version" => nil
            },
            context
          ),
        "lines" => lines
      })
    )
  end

  defp host_lines do
    [
      line("jason", "1.4.4", "miss", "not_built_version", ["1.4.4"]),
      line("decimal", "2.3.0", "hit", "hit", []),
      line("acme_secret", "0.1.0", "miss", "not_in_batch", [])
    ]
  end

  defp line(name, version, status, code, args),
    do: %{
      "name" => name,
      "version" => version,
      "status" => status,
      "detail" => "detail",
      "reason_code" => code,
      "reason_args" => args
    }

  # Non-interactive stdin counts as no, so every send passes --yes.
  defp report(dir, args \\ []) do
    System.cmd(
      "mix",
      ["precompiled.report", "--yes", "--contact", "e2e-tester for #{@app}" | args],
      cd: dir,
      stderr_to_stdout: true,
      env: child_env()
    )
  end

  defp reports do
    Repo.all(
      from(r in "precompiled_reports",
        select: %{
          id: type(r.id, Ecto.UUID),
          contact: r.contact,
          seen: r.seen_count,
          hits: r.hit_count,
          misses: r.miss_count,
          lock: r.lock,
          target: r.target,
          system: r.system,
          system_version: r.system_version,
          reporter_key: r.reporter_key
        },
        order_by: r.received_at
      )
    )
  end

  defp lines(id) do
    {:ok, uuid} = Ecto.UUID.dump(id)

    Repo.all(
      from(l in "precompiled_report_lines",
        where: l.report_id == ^uuid,
        select: {l.package, l.version, l.status, l.reason_code, l.reason_args, l.reason}
      )
    )
  end

  # Every stored row of both tables as JSON text.
  defp stored_text do
    for table <- ["precompiled_reports", "precompiled_report_lines"],
        [row] <- Repo.query!("SELECT row_to_json(t)::text FROM #{table} t").rows,
        into: "",
        do: row <> "\n"
  end

  test "a report is stored, a repeat is counted without an id, and the id retracts it",
       %{dir: dir, port: port} do
    write_report!(dir, %{}, host_lines())

    {out, 0} = report(dir)
    assert [_, id] = Regex.run(~r/report ([0-9a-f-]{36})/, out), out
    refute out =~ "already received"

    [row] = reports()
    assert row.id == id
    # Redaction touches contact (and reasons) only: the app name is gone
    # from the contact, the `jason` line and lock entry keep their name.
    assert row.contact == "e2e-tester for <redacted>"
    assert row.seen == 1 and row.hits == 1 and row.misses == 1
    assert row.target == "host" and row.system == nil
    assert row.lock["entries"] |> Enum.map(& &1["name"]) |> Enum.sort() == ["decimal", "jason"]
    assert row.reporter_key =~ ~r/\A[0-9a-f]{32}\z/

    # Only misses and fails are stored as lines; hits are counted.
    assert lines(id) == [
             {"jason", "1.4.4", "miss", "not_built_version", ["1.4.4"], "not built for 1.4.4"}
           ]

    text = stored_text()
    refute text =~ "acme"
    refute text =~ "127.0.0.1"
    refute text =~ dir

    # The same report again: counted, answered without an id.
    {out, 0} = report(dir)
    assert out =~ "already received"
    refute out =~ id
    refute out =~ ~r/report [0-9a-f-]{36}/
    assert [%{id: ^id, seen: 2}] = reports()

    # --dump: the exact JSON on stdout, everything else on stderr.
    {json, 0} =
      System.cmd(
        "sh",
        ["-c", "mix precompiled.report --dump --contact 'e2e-tester for #{@app}' 2>dump.err"],
        cd: dir,
        env: child_env()
      )

    dumped = Jason.decode!(json)
    assert dumped["contact"] == "e2e-tester for <redacted>"
    assert Enum.map(dumped["lines"], & &1["name"]) |> Enum.sort() == ["decimal", "jason"]
    refute json =~ "acme"
    assert File.read!(Path.join(dir, "dump.err")) =~ "destination: http://127.0.0.1:#{port}"
    assert [%{seen: 2}] = reports()

    # Retract by the printed id: 204, and the report and its lines are gone.
    url = "http://127.0.0.1:#{port}/api/precompiled/reports/#{id}"
    assert %Req.Response{status: 204} = Req.delete!(url, retry: false)
    assert reports() == []
    assert lines(id) == []
    assert %Req.Response{status: 404} = Req.delete!(url, retry: false)
  end

  test "a Nerves system that is not a public Hex package goes out as custom", %{dir: dir} do
    write_report!(
      dir,
      %{"target" => "rpi4", "system" => "nerves_system_acme", "system_version" => "1.2.3"},
      [
        line("jason", "1.4.4", "miss", "not_built_target", ["rpi4", "nerves_system_acme"]),
        line("acme_secret", "0.1.0", "miss", "not_in_batch", [])
      ]
    )

    {out, 0} = report(dir)
    assert [_, id] = Regex.run(~r/report ([0-9a-f-]{36})/, out), out

    [row] = reports()
    assert row.id == id
    assert {row.target, row.system, row.system_version} == {"custom", "custom", nil}

    assert lines(id) == [
             {"jason", "1.4.4", "miss", "not_built_target", ["custom", "custom"],
              "not built for custom custom"}
           ]

    text = stored_text()
    refute text =~ "acme"
    refute text =~ "rpi4"
  end
end
