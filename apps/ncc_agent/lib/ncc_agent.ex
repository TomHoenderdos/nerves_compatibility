defmodule NccAgent do
  @moduledoc """
  The remote builder agent. It runs on a builder host, holds an mTLS
  identity issued by the portal's builder CA (`NccAgent.Identity`), and
  talks to the portal's `/builder/v1` API through `NccAgent.Client`.

  Configuration comes from the environment (`NccAgent.Config`); see the
  app's README and `docs/REMOTE_BUILDERS.md`.
  """
end
