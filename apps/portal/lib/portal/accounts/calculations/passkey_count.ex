defmodule Portal.Accounts.Calculations.PasskeyCount do
  @moduledoc """
  How many passkeys a user has, for the admin Users table: an admin without
  one cannot open the admin pages, which the table flags.

  Counted for the whole page of users in one query rather than through
  `Portal.Accounts.Mfa.factors/1` per user, which would cost two queries a
  row (the passkey count and a TOTP lookup the table does not show).
  """
  use Ash.Resource.Calculation

  require Ash.Query

  @impl true
  def calculate(users, _opts, _context) do
    ids = Enum.map(users, & &1.id)

    counts =
      Portal.Accounts.Passkey
      |> Ash.Query.filter(user_id in ^ids)
      |> Ash.Query.select([:user_id])
      |> Ash.read!(domain: Portal.Accounts)
      |> Enum.frequencies_by(& &1.user_id)

    Enum.map(users, &Map.get(counts, &1.id, 0))
  end
end
