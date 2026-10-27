defmodule PortalWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use PortalWeb, :html

  # Also brings `verification_label/1` and `request_status_label/1`, which the
  # request-scan template shares with the admin Queue tab.
  import PortalWeb.AdminComponents

  embed_templates "page_html/*"
end
