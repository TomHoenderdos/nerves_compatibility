defmodule PortalWeb.ArgusExportController do
  @moduledoc """
  argus results as newline-delimited JSON, one run per line, for the people
  reviewing argus's false-positive rate. Admin (passkey) only, through the
  `:admin` pipeline. See `Portal.Catalog.argus_export/1` for what a line holds.
  """
  use PortalWeb, :controller

  alias Portal.Catalog

  def export(conn, params) do
    scope = if params["scope"] == "all", do: :all, else: :latest

    case since(params["since"]) do
      {:ok, since} ->
        stream(conn, scope, since)

      :error ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "since must be an ISO 8601 timestamp, e.g. 2026-10-01T00:00:00Z\n")
    end
  end

  defp since(nil), do: {:ok, nil}
  defp since(""), do: {:ok, nil}

  defp since(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} ->
        {:ok, at}

      {:error, _} ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
          {:error, _} -> :error
        end
    end
  end

  defp stream(conn, scope, since) do
    filename = "argus-#{scope}-#{Date.utc_today()}.ndjson"

    conn =
      conn
      |> put_resp_content_type("application/x-ndjson")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_chunked(200)

    Catalog.argus_export(scope: scope, since: since)
    |> Stream.map(&[Jason.encode_to_iodata!(&1), ?\n])
    |> Stream.chunk_every(50)
    |> Enum.reduce_while(conn, fn lines, conn ->
      case chunk(conn, lines) do
        {:ok, conn} -> {:cont, conn}
        # Bandit reports a dropped client as {:error, :closed} and other
        # transport failures as other reasons; either way, stop streaming.
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end
end
