defmodule Portal.Precompiled.Content do
  @moduledoc """
  Content origins: CDNs or mirrors that a signed batch tells clients they may
  fetch files, by-sha manifests and systems tables from (`content` in the
  batch payload), before the source. Each one serves this API's
  content-addressed paths under its own prefix: `<origin>/files/<sha>`,
  `<origin>/manifests/by-sha/<sha>.json`,
  `<origin>/v2/manifests/by-sha/<sha>.json`,
  `<origin>/systems/by-sha/<sha>.json`. Clients hash everything they
  fetch, so an origin can only cause a fallback, never a wrong install.

  Set by `NCC_PRECOMPILED_CONTENT_ORIGINS`, comma-separated. Each origin is
  `https` with a host and no userinfo, query, fragment or trailing slash; a
  path is allowed. A setting with any invalid entry is ignored as a whole
  and logged: batches keep signing, without `content`, so clients use the
  source as before. See `docs/PRECOMPILED_CDN.md`.
  """
  require Logger

  @max 8

  @spec origins() :: [String.t()]
  def origins do
    case parse(Application.get_env(:portal, :precompiled_content_origins)) do
      {:ok, origins} ->
        origins

      {:error, why} ->
        Logger.error("NCC_PRECOMPILED_CONTENT_ORIGINS ignored, batches carry no content: #{why}")
        []
    end
  end

  @spec parse(String.t() | nil) :: {:ok, [String.t()]} | {:error, String.t()}
  def parse(nil), do: {:ok, []}

  def parse(raw) when is_binary(raw) do
    entries = raw |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    cond do
      length(entries) > @max ->
        {:error, "more than #{@max} origins"}

      (bad = Enum.reject(entries, &origin?/1)) != [] ->
        {:error, bad_entries_message(bad)}

      true ->
        {:ok, Enum.uniq(entries)}
    end
  end

  # Names every bad entry, not just the first: a single typo-laden setting
  # should not take two boot cycles (fix one, discover the next) to clean up.
  defp bad_entries_message(bad) do
    names = Enum.map_join(bad, ", ", &inspect/1)
    verb = if length(bad) == 1, do: "is", else: "are"

    "#{names} #{verb} not an https origin without userinfo, query, fragment or trailing slash"
  end

  @spec origin?(String.t()) :: boolean()
  def origin?(s) when is_binary(s) do
    case URI.new(s) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}}
      when is_binary(host) and host != "" ->
        not String.ends_with?(s, "/")

      _ ->
        false
    end
  end
end
