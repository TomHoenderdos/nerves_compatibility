defmodule Portal.Test.ReportFixtures do
  @moduledoc "Report bodies, as the precompiled client sends them."

  @doc "A valid body (string keys) with `overrides` merged over the top level."
  def body(overrides \\ %{}) do
    Map.merge(
      %{
        "format" => 1,
        "client" => "0.4.0",
        "built_at" => "2026-11-10T12:00:00Z",
        "elixir" => "1.20.3",
        "otp" => 29,
        "os" => %{"family" => "unix", "arch" => "aarch64-apple-darwin"},
        "target" => "rpi4",
        "system" => "nerves_system_rpi4",
        "system_version" => "1.31.0",
        "lines" => [
          line("ash", "3.5.2", "hit", "hit", []),
          line("jason", "1.4.5", "miss", "not_built_version", ["1.4.5"]),
          line("circuits_uart", "1.5.1", "fail", "fetch_failed", [])
        ],
        "lock" => [
          lock("ash", "3.5.2"),
          lock("jason", "1.4.5"),
          lock("circuits_uart", "1.5.1")
        ]
      },
      overrides
    )
  end

  @doc "Validates `body(overrides)` and records it; the report id, or `:duplicate`."
  def record!(overrides \\ %{}, opts \\ []) do
    {:ok, payload} = Portal.Reports.Payload.validate(body(overrides))
    key = Keyword.get(opts, :reporter_key, "r" <> String.duplicate("0", 31))

    case Portal.Reports.record(payload, key, Keyword.take(opts, [:now])) do
      {:created, id} -> id
      :duplicate -> :duplicate
    end
  end

  def line(name, version, status, code, args) do
    %{
      "name" => name,
      "version" => version,
      "status" => status,
      "reason_code" => code,
      "reason_args" => args,
      "reason" => "#{code} #{Enum.join(args, " ")}"
    }
  end

  def lock(name, version) do
    %{
      "name" => name,
      "version" => version,
      "checksum" => :crypto.hash(:sha256, name <> version) |> Base.encode16(case: :lower)
    }
  end
end
