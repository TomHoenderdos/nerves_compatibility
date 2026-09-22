defmodule PortalWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use PortalWeb, :html

  embed_templates "page_html/*"

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :page, :map, required: true
  attr :params, :map, required: true
  attr :param, :atom, required: true

  def admin_pagination(assigns) do
    ~H"""
    <nav
      :if={@page.total > 0}
      id={@id}
      aria-label={@label}
      class="mt-4 flex flex-wrap items-center justify-between gap-3 text-sm"
    >
      <p>
        {@page.offset + 1}–{@page.offset + length(@page.entries)} of {@page.total}
        <span class="text-base-content/60">· Page {@page.page} of {@page.total_pages}</span>
      </p>
      <div class="flex gap-2">
        <.link
          :if={@page.page > 1}
          href={~p"/admin?#{Map.put(@params, @param, 1)}"}
          class="btn btn-sm btn-ghost"
        >
          First
        </.link>
        <.link
          :if={@page.page > 1}
          href={~p"/admin?#{Map.put(@params, @param, @page.page - 1)}"}
          rel="prev"
          class="btn btn-sm btn-outline"
        >
          Previous
        </.link>
        <.link
          :if={@page.page < @page.total_pages}
          href={~p"/admin?#{Map.put(@params, @param, @page.page + 1)}"}
          rel="next"
          class="btn btn-sm btn-outline"
        >
          Next
        </.link>
        <.link
          :if={@page.page < @page.total_pages}
          href={~p"/admin?#{Map.put(@params, @param, @page.total_pages)}"}
          class="btn btn-sm btn-ghost"
        >
          Last
        </.link>
      </div>
    </nav>
    """
  end

  attr :queue_page, :integer, required: true
  attr :review_page, :integer, required: true

  def admin_page_fields(assigns) do
    ~H"""
    <input type="hidden" name="queue_page" value={@queue_page} />
    <input type="hidden" name="review_page" value={@review_page} />
    """
  end

  def verification_label(:hex_owner), do: "Hex.pm owner"
  def verification_label(:github_repo), do: "GitHub repository"
  def verification_label(:anonymous_turnstile), do: "Anonymous"
  def verification_label(:anonymous_manual), do: "Manual review"
  def verification_label(:admin_manual), do: "Admin"
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
