defmodule PortalWeb.AdminMessages do
  @moduledoc """
  The texts an admin action shows when it is refused. Shared by
  `PortalWeb.PageController` and the admin LiveViews so a refusal reads the
  same on both.
  """

  def error(:not_found), do: "Request was not found."
  def error(:not_pending_anonymous), do: "Request is no longer pending review."
  def error(:blank_package_name), do: "Enter a package name."

  def error(:invalid_package_name),
    do: "That does not look like a hex.pm package name."

  def error({:already_open, request}),
    do:
      "#{request.package_name} already has an open request (#{request.status}). " <>
        "Tick \"force a rebuild\" to queue another build anyway."

  def error(:unknown_package), do: "hex.pm does not know that package."

  def error(:unknown_package_version),
    do: "hex.pm has no released version of that."

  def error(:no_job), do: "No build job for that request -- nothing to reorder."

  def error({:not_adjustable, state}),
    do: "That build is already #{state}; its priority no longer affects anything."

  def error(:already_at_limit), do: "Already at the end of the priority range."
  def error(:already_queued), do: "An update check is already queued."

  def error(:invalid_argus_settings),
    do: "Tick at least one analysis and keep the timeout between 30 and 1800 seconds."

  def error(:blank_username), do: "Enter a username."

  def error(:unknown_user),
    do: "No account with that username. They need to register first."

  def error(:self), do: "You cannot remove your own admin access."

  def error(:own_password),
    do: "Change your own password on the settings page."

  def error(:last_admin), do: "That is the last admin; grant someone else first."
  def error(:not_admin), do: "That account is not an admin."

  def error(:no_ca),
    do: "No builder CA is configured; run portal.builder_ca.init first."

  def error(:invalid_name),
    do:
      "A builder name is a letter or digit, then up to 63 letters, digits, dots, dashes or underscores."

  def error(:not_failed),
    do: "That lease is no longer failed; only a failed lease can be requeued."

  def error(:invalid_remote_settings),
    do: "Choose auto, on or off, and a backlog threshold of zero or more."

  def error(_), do: "Admin action failed."
end
