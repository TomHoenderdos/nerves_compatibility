defmodule PortalWeb.CinderTheme do
  @moduledoc """
  Cinder tables in the admin pages look like the daisyUI tables they replace.
  """

  use Cinder.Theme
  extends :daisy_ui

  # Plain `table`, not `daisy_ui`'s `table table-zebra`: the hand-written
  # admin tables these replace don't zebra-stripe.
  set :table_class, "table"

  # `daisy_ui`'s card-styled wrapper doesn't match the admin tables, which
  # wrap their `<table>` in a plain scroll container.
  set :table_wrapper_class, "overflow-x-auto"

  # Empty, so header cells render as bare daisyUI `<th>`s, as in the
  # hand-written admin tables, instead of `daisy_ui`'s bold/no-wrap styling.
  set :th_class, ""

  # Drop `daisy_ui`'s `bg-base-100` fill so pagination buttons match the
  # plain `btn btn-sm` used elsewhere in the admin pages.
  set :pagination_button_class, "btn btn-sm"

  # Smaller (`-sm`) to fit the admin pages' compact filter rows; `daisy_ui`
  # sizes these for its own standalone filter panel.
  set :filter_text_input_class, "input input-sm input-bordered"
  set :filter_select_input_class, "select select-sm select-bordered"
end
