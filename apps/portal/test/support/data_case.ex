defmodule Portal.DataCase do
  @moduledoc """
  Test case for tests that touch the database.

  Wraps each test in an `Ecto.Adapters.SQL.Sandbox` transaction so changes
  are rolled back at the end of every test, keeping the database clean.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Portal.Repo
      import Ecto.Query

      import Portal.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Portal.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
