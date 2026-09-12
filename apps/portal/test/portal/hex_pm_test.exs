defmodule Portal.HexPmTest do
  use ExUnit.Case, async: true

  alias Portal.HexPm

  describe "scope/0" do
    test "requests read-only access" do
      assert HexPm.scope() == "api:read"
    end

    test "never requests write access" do
      # Hex.pm expands the bare "api" scope into api:read + api:write on its
      # consent screen. Portal only reads (GET /api/users/me), so widening this
      # would show users a write permission we never use and force 2FA on them.
      refute HexPm.scope() =~ "write"
      refute HexPm.scope() == "api"
    end
  end

  describe "metadata_from_body/1" do
    # This is the shape hex.pm actually returns -- confirmed against
    # `GET https://hex.pm/api/packages/jason`, which carries an `email` for
    # every owner. Dropping it here, at the boundary, is the only thing that
    # keeps a maintainer's address out of our database and off the public page.
    test "an owner's email never leaves the boundary" do
      body = %{
        "owners" => [
          %{"username" => "michalmuskala", "email" => "someone@example.com", "url" => "..."}
        ]
      }

      assert %{owners: ["michalmuskala"]} = HexPm.metadata_from_body(body)
      refute inspect(HexPm.metadata_from_body(body)) =~ "example.com"
    end

    test "links come through with their author-declared labels" do
      body = %{"meta" => %{"links" => %{"GitHub" => "https://github.com/michalmuskala/jason"}}}

      assert %{links: %{"GitHub" => "https://github.com/michalmuskala/jason"}} =
               HexPm.metadata_from_body(body)
    end

    # `meta.links` is a free-form map the package author writes in their own
    # mix.exs, and its values become `href`s on a public page. A `javascript:`
    # URL there would be stored XSS delivered through hex.pm.
    test "a link that is not an absolute http(s) URL is dropped" do
      body = %{
        "meta" => %{
          "links" => %{
            "XSS" => "javascript:alert(1)",
            "Data" => "data:text/html,<script>alert(1)</script>",
            "Relative" => "/docs",
            "Schemeless" => "github.com/foo/bar",
            "Empty host" => "https://",
            "Good" => "https://example.com/ok"
          }
        }
      }

      assert %{links: links} = HexPm.metadata_from_body(body)
      assert links == %{"Good" => "https://example.com/ok"}
    end

    # Nothing upstream caps any of this, so without these one package could
    # write an unbounded blob into every row of our table.
    test "an oversized payload is capped rather than stored whole" do
      links = for i <- 1..50, into: %{}, do: {"link-#{i}", "https://example.com/#{i}"}

      body = %{
        "meta" => %{
          "links" =>
            Map.merge(links, %{
              String.duplicate("x", 200) => "https://example.com/long-label",
              "Long URL" => "https://example.com/" <> String.duplicate("y", 400)
            })
        },
        "owners" => for(i <- 1..40, do: %{"username" => "owner#{i}"})
      }

      assert %{links: capped_links, owners: owners} = HexPm.metadata_from_body(body)

      assert map_size(capped_links) <= 20
      assert Enum.all?(Map.keys(capped_links), &(String.length(&1) <= 60))
      refute Map.has_key?(capped_links, "Long URL")
      assert length(owners) <= 25
    end

    test "a package with neither links nor owners yields empty collections" do
      assert HexPm.metadata_from_body(%{}) == %{links: %{}, owners: []}
    end

    # hex.pm sends `null` for both fields on some packages, which `List.wrap/1`
    # and the map guard have to absorb rather than raise on.
    test "nulls upstream are not a crash here" do
      assert HexPm.metadata_from_body(%{"meta" => %{"links" => nil}, "owners" => nil}) ==
               %{links: %{}, owners: []}
    end

    test "a body that is not a map yields empty collections" do
      assert HexPm.metadata_from_body("nope") == %{links: %{}, owners: []}
    end
  end
end
