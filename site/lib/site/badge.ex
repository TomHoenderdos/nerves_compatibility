defmodule Site.Badge do
  @moduledoc """
  Generates SVG status badges for packages.
  """

  @doc """
  Generates an SVG badge for a package's compatibility status.

  Returns an SVG string showing the overall compatibility status.
  """
  @spec generate(String.t(), map()) :: String.t()
  def generate(package_name, package_data) do
    {status, color} = calculate_status(package_data.systems)

    # Calculate text widths (approximate)
    label = "nerves"
    label_width = String.length(label) * 6 + 10
    status_width = String.length(status) * 6 + 10
    total_width = label_width + status_width

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{total_width}" height="20" role="img" aria-label="#{label}: #{status}">
      <title>#{package_name} Nerves compatibility: #{status}</title>
      <linearGradient id="s" x2="0" y2="100%">
        <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>
        <stop offset="1" stop-opacity=".1"/>
      </linearGradient>
      <clipPath id="r">
        <rect width="#{total_width}" height="20" rx="3" fill="#fff"/>
      </clipPath>
      <g clip-path="url(#r)">
        <rect width="#{label_width}" height="20" fill="#555"/>
        <rect x="#{label_width}" width="#{status_width}" height="20" fill="#{color}"/>
        <rect width="#{total_width}" height="20" fill="url(#s)"/>
      </g>
      <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" text-rendering="geometricPrecision" font-size="110">
        <text aria-hidden="true" x="#{label_width / 2 * 10}" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" textLength="#{(label_width - 10) * 10}">#{label}</text>
        <text x="#{label_width / 2 * 10}" y="140" transform="scale(.1)" fill="#fff" textLength="#{(label_width - 10) * 10}">#{label}</text>
        <text aria-hidden="true" x="#{(label_width + status_width / 2) * 10}" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" textLength="#{(status_width - 10) * 10}">#{status}</text>
        <text x="#{(label_width + status_width / 2) * 10}" y="140" transform="scale(.1)" fill="#fff" textLength="#{(status_width - 10) * 10}">#{status}</text>
      </g>
    </svg>
    """
  end

  defp calculate_status(systems) do
    system_list = Map.values(systems)
    total = length(system_list)

    if total == 0 do
      {"unknown", "#9ca3af"}
    else
      pass_count = Enum.count(system_list, &(&1.status == :pass))
      fail_count = Enum.count(system_list, &(&1.status == :fail))
      error_count = Enum.count(system_list, &(&1.status == :error))

      cond do
        pass_count == total ->
          {"passing", "#22c55e"}

        fail_count > 0 or error_count > 0 ->
          {"#{pass_count}/#{total} passing", "#f97316"}

        true ->
          {"#{pass_count}/#{total} passing", "#eab308"}
      end
    end
  end
end
