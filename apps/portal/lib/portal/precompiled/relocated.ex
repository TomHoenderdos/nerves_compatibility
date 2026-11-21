defmodule Portal.Precompiled.Relocated do
  @moduledoc """
  Relocated builds on the portal (S4): a toolchain build whose own beams
  bake its builder's deps or build path, served with the worker's record of
  every occurrence, which client 0.9.0 and later rewrite to the project's
  own paths at install (`Compatibility.Relocation`). Such a build counts as
  one only while its record's run mark is its own `run_id` (`counted/1`),
  and renders only under a version's `relocated` object while the
  `relocated_enabled` setting is on (`Portal.Catalog`), where clients
  before 0.9.0 never read: a byte copy of one would hold the builder's path.

  A dependent that passed only because a dependency was held is one too
  (the umbrella re-review's Q1): its record lists the three roots and often
  no file to rewrite, but its pass rests on the same residual (a test of
  the dependency's path that all three roots answer alike), so it is
  stored, gated, counted and revoked the same way, and the client's
  envelope holds it.
  """

  @doc "A build's relocation record while it is its own run's, else nil."
  @spec counted(map()) :: map() | nil
  def counted(%{relocation: %{} = record, run_id: run_id, relocation_run_id: run_id})
      when is_binary(run_id),
      do: record

  def counted(_build), do: nil

  @spec enabled?() :: boolean()
  def enabled?, do: Portal.Settings.get().relocated_enabled == true
end
