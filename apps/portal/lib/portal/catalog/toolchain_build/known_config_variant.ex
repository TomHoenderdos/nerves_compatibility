defmodule Portal.Catalog.ToolchainBuild.KnownConfigVariant do
  @moduledoc """
  Refuses a toolchain build whose `config_variant` is neither `"default"` nor
  a `Compatibility.ConfigVariants` name (`Compatibility.ConfigVariants.known?/1`).
  """
  use Ash.Resource.Validation

  alias Compatibility.ConfigVariants

  @impl true
  def validate(changeset, _opts, _context) do
    value = Ash.Changeset.get_attribute(changeset, :config_variant)

    if ConfigVariants.known?(value) do
      :ok
    else
      {:error, field: :config_variant, message: "is not a known config variant"}
    end
  end
end
