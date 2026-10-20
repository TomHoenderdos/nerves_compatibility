defmodule PortalWeb.AdminMessagesTest do
  use ExUnit.Case, async: true
  alias PortalWeb.AdminMessages

  test "known reasons keep their exact admin texts" do
    assert AdminMessages.error(:not_pending_anonymous) == "Request is no longer pending review."
    assert AdminMessages.error(:last_admin) == "That is the last admin; grant someone else first."

    assert AdminMessages.error({:not_adjustable, "executing"}) ==
             "That build is already executing; its priority no longer affects anything."
  end

  test "an unknown reason falls back to a generic text" do
    assert AdminMessages.error(:something_new) == "Admin action failed."
  end
end
