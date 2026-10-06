defmodule Portal.ScanRequests.FailureSummary do
  @moduledoc """
  The few lines of a failed build's runner excerpt that say why it failed.

  A runner excerpt is the last 16 KB of the log, and most of it is compiler
  warnings; the cause sits at the very end. This pulls it out for the request
  page and the admin failures card: the last Elixir/Erlang exception with the
  top of its stack trace, or failing that the last lines that read like an
  error. The excerpt itself is already sanitised by `Portal.Catalog.LogSanitizer`.
  """

  @stack_lines 6
  @error_lines 4

  # Lines that report a failure without an exception: make, mix compile, the
  # worker's own policy message.
  @error_line ~r/(\berror\b|\bError \d+|could not compile|failed|Worker failed)/i

  # Builder's footer and section rules are bookkeeping, not the cause.
  @noise ~r/^(=+|Docker exit status:|Completed:|Started:)/

  @doc "The failure lines of `log`, or nil when nothing in it reads as a cause."
  @spec from_log(String.t() | nil) :: String.t() | nil
  def from_log(log) when is_binary(log) and log != "" do
    lines = String.split(log, "\n")
    exception(lines) || error_lines(lines)
  end

  def from_log(_log), do: nil

  defp exception(lines) do
    case lines |> Enum.with_index() |> Enum.filter(fn {l, _} -> exception_line?(l) end) do
      [] ->
        nil

      found ->
        {_line, at} = List.last(found)

        lines
        |> Enum.drop(at)
        |> Enum.take(1 + @stack_lines)
        |> Enum.take_while(&(String.trim(&1) != "" and not Regex.match?(@noise, &1)))
        |> Enum.map_join("\n", &String.trim_trailing/1)
    end
  end

  defp exception_line?(line), do: String.starts_with?(String.trim_leading(line), "** (")

  defp error_lines(lines) do
    case lines
         |> Enum.reject(&Regex.match?(@noise, String.trim(&1)))
         |> Enum.filter(&Regex.match?(@error_line, &1))
         |> Enum.take(-@error_lines) do
      [] -> nil
      found -> Enum.map_join(found, "\n", &String.trim/1)
    end
  end
end
