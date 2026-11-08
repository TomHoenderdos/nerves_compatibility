defmodule Compatibility.ConfigVariants.PhxNewTest do
  use ExUnit.Case, async: true

  alias Compatibility.ConfigVariants
  alias Compatibility.ConfigVariants.PhxNew

  @config ~S'''
  config :<%= @app_name %>, <%= @endpoint_module %>,
    url: [host: "localhost"],
    pubsub_server: <%= @app_module %>.PubSub,
    live_view: [signing_salt: "<%= @lv_signing_salt %>"]<%= if @live do %>

  config :phoenix_live_view,
    # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
    root_tag_attribute: "phx-r"<% end %><%= if @mailer do %>

  # Configure the mailer
  config :<%= @app_name %>, <%= @app_module %>.Mailer, adapter: Swoosh.Adapters.Local<% end %>

  config :logger, :default_formatter,
    format: "$time $metadata[$level] $message\n",
    metadata: [:request_id]

  # Use Jason for JSON parsing in Phoenix
  config :phoenix, :json_library, Jason

  import_config "#{config_env()}.exs"
  '''

  @dev ~S'''
  config :phoenix, :stacktrace_depth, 20

  # Initialize plugs at runtime for faster development compilation
  config :phoenix, :plug_init_mode, :runtime<%= if @html do %>

  config :phoenix_live_view,
    # Include debug annotations and locations in rendered markup.
    # Changing this configuration will require mix clean and a full recompile.
    debug_heex_annotations: true,
    debug_attributes: true,
    # Enable helpful, but potentially expensive runtime checks
    enable_expensive_runtime_checks: true<% end %><%= if @mailer do %>

  config :swoosh, :api_client, false<% end %>
  '''

  @test ~S'''
  config :logger, level: :warning

  # Initialize plugs at runtime for faster test compilation
  config :phoenix, :plug_init_mode, :runtime<%= if @html do %>

  # Enable helpful, but potentially expensive runtime checks
  config :phoenix_live_view,
    enable_expensive_runtime_checks: true<% end %>

  # Sort query params output of verified routes for robust url comparisons
  config :phoenix,
    sort_verified_routes_query_params: true
  '''

  @prod ~S'''
  config :logger, level: :info
  '''

  @templates %{
    "config.exs" => @config,
    "dev.exs" => @dev,
    "test.exs" => @test,
    "prod.exs" => @prod
  }

  test "phx_new 1.8.16's templates read back to exactly the pinned overlays" do
    overlays = PhxNew.overlays(@templates)

    for name <- ConfigVariants.names() do
      {:ok, pinned} = ConfigVariants.overlay(name)
      assert Enum.sort(overlays[name]) == Enum.sort(pinned), name
    end

    assert PhxNew.drift(@templates) == []
  end

  test "a new LiveView key in a later phx_new is drift" do
    templates =
      Map.update!(
        @templates,
        "dev.exs",
        &(&1 <> "\nconfig :phoenix_live_view, debug_tags: true\n")
      )

    assert ["phx_dev: phoenix_live_view debug_tags set by phx_new, not by the overlay"] =
             PhxNew.drift(templates)
  end

  test "a changed value and a dropped key are drift" do
    changed = Map.update!(@templates, "config.exs", &String.replace(&1, ~s("phx-r"), ~s("phx-x")))
    drift = PhxNew.drift(changed)
    assert "phx_prod: phoenix_live_view root_tag_attribute differs" in drift

    dropped =
      Map.update!(
        @templates,
        "test.exs",
        &String.replace(&1, "sort_verified_routes_query_params: true", "")
      )

    assert "phx_test: phoenix sort_verified_routes_query_params set by the overlay, not by phx_new" in PhxNew.drift(
             dropped
           )
  end

  test "a value that is not a literal is drift, never evaluated" do
    templates =
      Map.update!(
        @templates,
        "config.exs",
        &(&1 <> "\nconfig :phoenix, :json_library, System.get_env(\"X\")\n")
      )

    assert Enum.any?(PhxNew.drift(templates), &String.contains?(&1, "not a literal"))
  end

  test "reading a template creates no atom" do
    key = "ncc_never_an_atom_#{System.unique_integer([:positive])}"

    templates =
      Map.update!(@templates, "dev.exs", &(&1 <> "\nconfig :phoenix, #{key}: :#{key}_value\n"))

    assert "phx_dev: phoenix #{key} set by phx_new, not by the overlay" in PhxNew.drift(templates)
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(key <> "_value") end
  end
end
