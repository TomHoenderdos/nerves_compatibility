defmodule NccWorker.RequestedOptionalDepsTest do
  # The portal records a toolchain build as the variant it queued it as, and
  # checks the result's echo of the request against it.
  use ExUnit.Case, async: true

  alias NccWorker.Worker

  test "a toolchain result echoes the optional_deps request" do
    for request <- ["include", "exclude"] do
      assert %{requested_optional_deps: ^request} =
               Worker.put_requested_optional_deps(%{scope: "toolchain"}, request)
    end
  end

  test "a run given no request echoes none" do
    assert Worker.put_requested_optional_deps(%{scope: "toolchain"}, nil) == %{scope: "toolchain"}
  end
end
