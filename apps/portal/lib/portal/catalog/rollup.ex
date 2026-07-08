defmodule Portal.Catalog.Rollup do
  @moduledoc "Pure package-level rollups over per-system results."

  @doc "Roll a list of per-system statuses into one package-level bucket."
  @spec overall_status([atom() | String.t()]) :: :pass | :fail | :partial | :skipped | :unknown
  def overall_status([]), do: :unknown

  def overall_status(statuses) do
    s = Enum.map(statuses, &to_string/1)

    cond do
      Enum.any?(s, &(&1 in ["fail", "error"])) -> :fail
      Enum.all?(s, &(&1 == "pass")) -> :pass
      Enum.all?(s, &(&1 == "skipped")) -> :skipped
      Enum.any?(s, &(&1 == "pass")) -> :partial
      true -> :unknown
    end
  end

  @doc "Classify a package's native-code bucket."
  @spec native_bucket(String.t() | nil, [String.t()], boolean()) :: String.t()
  def native_bucket(_nif, _ports, false), do: "not scanned"
  def native_bucket(nif, _ports, true) when is_binary(nif) and nif != "", do: nif

  def native_bucket(_nif, ports, true) do
    case Enum.reject(ports || [], &(is_nil(&1) or &1 == "")) do
      [lang | _] -> lang
      [] -> "none"
    end
  end
end
