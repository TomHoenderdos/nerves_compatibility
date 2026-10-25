defmodule Portal.Builders do
  @moduledoc """
  Ash domain for remote builders: the machines (`Builder`), their
  certificate history (`BuilderCertificate`), one-time enrolment tokens and
  the remote job queue (`Lease`). Context functions live here too; the
  resources carry only attributes and actions.
  """
  use Ash.Domain

  resources do
    resource(Portal.Builders.Builder)
    resource(Portal.Builders.BuilderCertificate)
    resource(Portal.Builders.EnrolmentToken)
    resource(Portal.Builders.Lease)
  end
end
