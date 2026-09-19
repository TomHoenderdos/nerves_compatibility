defmodule PortalWeb.MfaHTML do
  @moduledoc """
  Templates for the second-factor step.
  """

  use PortalWeb, :html

  embed_templates("mfa_html/*")
end
