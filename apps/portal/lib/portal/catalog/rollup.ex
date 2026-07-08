defmodule Portal.Catalog.Rollup do
  @moduledoc """
  Rolls up per-system results into package-level buckets.
  """

  @doc """
  Rolls per-system statuses into a single package status bucket.

  Priority: fail > error > partial > pass > skipped > unknown.

  - If any system is :fail or "fail" (or :error or "error"), returns :fail.
  - If any system is :skipped or "skipped" but none failed/errored, and others are :pass, returns :partial.
  - If all are :skipped or "skipped", returns :skipped.
  - If all are :pass or "pass", returns :pass.
  - If list is empty, returns :unknown.
  - Otherwise returns :unknown.
  """
  def overall_status(statuses) when is_list(statuses) do
    normalized = Enum.map(statuses, &normalize_status/1)

    cond do
      Enum.any?(normalized, &(&1 in [:fail, :error])) ->
        :fail

      Enum.any?(normalized, &(&1 == :skipped)) and Enum.any?(normalized, &(&1 == :pass)) ->
        :partial

      Enum.all?(normalized, &(&1 == :skipped)) and length(normalized) > 0 ->
        :skipped

      Enum.all?(normalized, &(&1 == :pass)) and length(normalized) > 0 ->
        :pass

      length(normalized) == 0 ->
        :unknown

      true ->
        :unknown
    end
  end

  defp normalize_status(status) when is_binary(status) do
    String.to_atom(status)
  end

  defp normalize_status(status) when is_atom(status) do
    status
  end

  @doc """
  Classifies native language presence for a build.

  Returns a classification string:
  - If nif_language is provided, returns it.
  - If port_languages is non-empty, returns the first language.
  - If any_scanned? is false, returns "not scanned".
  - Otherwise returns "none".
  """
  def native_bucket(nif_language, port_languages, any_scanned?) do
    cond do
      is_binary(nif_language) and nif_language != "" ->
        nif_language

      is_list(port_languages) and length(port_languages) > 0 ->
        List.first(port_languages)

      not any_scanned? ->
        "not scanned"

      true ->
        "none"
    end
  end
end
