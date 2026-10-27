defmodule PortalWeb.Admin.LiveAuth do
  @moduledoc """
  What every admin LiveView does around its own work: re-check the admin on
  each click and bulk action, refuse the way the `/admin` gate does, and keep
  untrusted event and URL params from crashing the page.

  The re-check is the point. `live_session :admin`'s `on_mount` runs the admin
  policy when the page mounts, and the socket keeps the user it found there.
  A click or a bulk action is checked again here against the user as the
  database has them now (`PortalWeb.Plugs.RequireAdmin.check_session/3`), as
  the controller pages these replace checked every request: an admin demoted
  or stripped of their passkey while the page is open is refused on the next
  click, not when the socket happens to reconnect. Cinder's own paging and
  filtering, which never pass through here, are cut off by disconnecting the
  socket instead (`Portal.Accounts.disconnect_live_sockets/1`).

  Each page keeps `:user_id`, `:login_method` and `:session_started_at` from
  its session in its assigns for this; nothing here reads them from anywhere
  else. The start time is what refuses a click from a page whose sessions
  were revoked (`Portal.Accounts.revoke_sessions/1`) and that missed the
  disconnect.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  alias PortalWeb.Plugs.RequireAdmin

  @doc """
  Runs `fun.(socket, user)` if the page's session still belongs to an admin,
  with `user` freshly loaded and assigned as `:current_user`; otherwise
  refuses as `refuse/2` does.
  """
  @spec as_admin(Phoenix.LiveView.Socket.t(), (Phoenix.LiveView.Socket.t(), map() -> result)) ::
          result | {:noreply, Phoenix.LiveView.Socket.t()}
        when result: term()
  def as_admin(socket, fun) do
    %{user_id: user_id, login_method: login_method, session_started_at: started_at} =
      socket.assigns

    case RequireAdmin.check_session(user_id, login_method, started_at) do
      {:ok, user} -> fun.(assign(socket, :current_user, user), user)
      {:error, refusal} -> refuse(socket, refusal)
    end
  end

  @doc """
  Wraps `bulk_fun` as a Cinder bulk action that re-checks the admin first.

  Cinder calls a bulk action as `fun.(query, opts)`, with the actor it was
  rendered with. That actor is a snapshot from the mount, so the admin is
  re-checked here before anything else happens and the freshly loaded user
  goes in its place. A refusal comes back as `{:error, {:refused, refusal}}`,
  which Cinder hands to the page's `{:bulk_failed, _}` clause to redirect the
  way a click would, having started no work and changed nothing.

  Built once at mount, it closes over the session the page was opened with.
  """
  @spec as_admin_bulk(
          (term(), keyword() -> term()),
          String.t() | nil,
          atom() | nil,
          integer() | nil
        ) :: (term(), keyword() -> term())
  def as_admin_bulk(bulk_fun, user_id, login_method, started_at) do
    fn query, opts ->
      case RequireAdmin.check_session(user_id, login_method, started_at) do
        {:ok, user} -> bulk_fun.(query, Keyword.put(opts, :actor, user))
        {:error, refusal} -> {:error, {:refused, refusal}}
      end
    end
  end

  @doc "Flashes the refusal and sends the browser where the gate would."
  @spec refuse(Phoenix.LiveView.Socket.t(), RequireAdmin.refusal()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def refuse(socket, %{to: to, flash: flash}) do
    {:noreply, socket |> put_flash(:error, flash) |> redirect(to: to)}
  end

  @doc """
  The string a click put under `key`, or `""`.

  A click carries what the button put in it, but a forged one may carry
  anything; a missing or non-string value is refused by the context function
  as blank, unknown or invalid, not by crashing the page.
  """
  @spec string_param(map(), String.t()) :: String.t()
  def string_param(params, key) do
    case params[key] do
      value when is_binary(value) -> value
      _other -> ""
    end
  end

  @doc """
  `params` without a `page` Cinder cannot use.

  Cinder turns `page` into an offset unchecked, and one past Postgres's
  bigint fails the query and logs an error instead of showing anything. The
  controller pages fell back to a valid page; here an absurd one is dropped,
  which shows the first.
  """
  @spec sane_page(map()) :: map()
  def sane_page(%{"page" => page} = params) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n in 1..1_000_000 -> params
      _ -> Map.delete(params, "page")
    end
  end

  def sane_page(%{"page" => _not_a_string} = params), do: Map.delete(params, "page")

  def sane_page(params), do: params

  @doc """
  What `use Cinder.UrlSync` would inject as a `handle_info/2` clause, as a
  function, so each page's clause can sit with its other `handle_info/2`
  clauses.
  """
  @spec table_state_change(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def table_state_change(socket, encoded_state) do
    current_uri = get_in(socket.assigns, [:url_state, :uri])
    {:noreply, Cinder.UrlSync.update_url(socket, encoded_state, current_uri)}
  end
end
