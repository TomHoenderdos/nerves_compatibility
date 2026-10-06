defmodule PortalWeb.RequestRedirectController do
  @moduledoc """
  `/requests/:id` used to be a page of its own. The package page now shows a
  package's builds, so this only sends links already shared -- in confirmation
  panels, admin pages, people's bookmarks -- to the package they were about.
  """

  use PortalWeb, :controller

  def show(conn, %{"id" => id}) do
    case Portal.ScanRequests.get_request(id) do
      {:ok, request} ->
        redirect(conn, to: ~p"/packages/#{request.package_name}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Request not found")
        |> redirect(to: ~p"/packages")
    end
  end
end
