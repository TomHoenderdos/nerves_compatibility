defmodule PortalWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use PortalWeb, :html

  embed_templates "page_html/*"

  def verification_label(:hex_owner), do: "Hex.pm owner"
  def verification_label(:github_repo), do: "GitHub repository"
  def verification_label(:anonymous_turnstile), do: "Anonymous"
  def verification_label(:anonymous_manual), do: "Manual review"
  def verification_label(source), do: source |> to_string() |> String.replace("_", " ")

  def request_status_label(:pending), do: "Pending review"
  def request_status_label(:accepted), do: "Accepted"
  def request_status_label(:queued), do: "Queued"
  def request_status_label(:rejected), do: "Rejected"
  def request_status_label(status), do: status |> to_string() |> String.replace("_", " ")

  def format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  def format_datetime(_datetime), do: "-"
end
