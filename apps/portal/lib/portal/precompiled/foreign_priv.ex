defmodule Portal.Precompiled.ForeignPriv do
  @moduledoc """
  Foreign priv builds on the portal (foreign priv spec 4): a build whose
  compile wrote Kino.JS archives into kino's priv. Such a build counts as
  one only while its list's run mark is its own `run_id` (`counted/1`),
  renders only under a version's `foreign_priv` object while the
  `foreign_priv_enabled` setting is on (`Portal.Catalog`), and kino's own
  builds render only there too (phase 0b, `target?/1`), where clients
  before 0.8.0 never read.
  """

  @doc "A build's foreign entries while they are its own run's, else `[]`."
  @spec counted(map()) :: [map()]
  def counted(%{foreign_priv: [_ | _] = list, run_id: run_id, foreign_priv_run_id: run_id})
      when is_binary(run_id),
      do: list

  def counted(_build), do: []

  @spec enabled?() :: boolean()
  def enabled?, do: Portal.Settings.get().foreign_priv_enabled == true

  @doc "Whether `package` is the app foreign builds write into, whose own builds 0b moves."
  @spec target?(String.t() | nil) :: boolean()
  def target?(package), do: package == Compatibility.ForeignPriv.target()
end
