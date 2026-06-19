defmodule Portal.Seeds do
  @moduledoc """
  Seed helpers for release-safe portal setup.
  """

  def seed_admins_from_env! do
    admin_seed =
      System.get_env("PORTAL_SEED_ADMINS") ||
        System.get_env("PORTAL_ADMIN_SEED_USERS") ||
        ""

    shared_password = System.get_env("PORTAL_SEED_ADMIN_PASSWORD")

    admin_seed
    |> String.split(~r/[\n,;]+/, trim: true)
    |> Enum.each(fn entry ->
      {username, password} = parse_admin_entry(entry, shared_password)

      case Portal.Accounts.seed_admin_user(username, password) do
        {:ok, user} ->
          IO.puts("Seeded admin user #{user.username}")

        {:error, :password_required} ->
          raise """
          Cannot create admin user #{username} without a password.

          Either register the user first and rerun the seed to promote it, or provide:
            PORTAL_SEED_ADMINS="#{username}:a long temporary password"
          """

        {:error, reason} ->
          raise "Could not seed admin user #{username}: #{inspect(reason)}"
      end
    end)
  end

  defp parse_admin_entry(entry, shared_password) do
    case String.split(entry, ":", parts: 2) do
      [username, password] -> {username, password}
      [username] -> {username, shared_password}
    end
  end
end
