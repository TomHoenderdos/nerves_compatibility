defmodule Portal.HexRegistryTest do
  @moduledoc """
  Tests for `Portal.HexRegistry`.

  The fixtures are real registry resources: `:hex_registry.build_names/2` and
  `build_versions/2` produce exactly what `repo.hex.pm` serves -- protobuf,
  signed, gzipped -- and the module under test verifies and decodes them
  through the same `:hex_core` path it uses in production. Only the key
  differs: the suite generates its own RSA pair and passes the public half via
  the documented `:public_key` option, because hex.pm's private key is, of
  course, hex.pm's.

  That matters for what these tests are worth. A hand-rolled map fixture would
  prove the joining logic and nothing else; building the real wire format means
  the gzip, the signature check, the protobuf schema, and the field names are
  all under test too, and a `:hex_core` upgrade that moved any of them would
  fail here rather than in production.
  """

  use ExUnit.Case, async: true

  alias Portal.HexRegistry

  setup_all do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    %{private: private, public: public}
  end

  # `updated_at` is a protobuf `Timestamp`, so seconds since the epoch.
  defp names_resource(packages, private) do
    packages =
      Enum.map(packages, fn
        {name, seconds} ->
          %{name: name, updated_at: %{seconds: seconds, nanos: 0}}

        name when is_binary(name) ->
          %{name: name}
      end)

    :hex_registry.build_names(%{repository: "hexpm", packages: packages}, private)
  end

  defp versions_resource(packages, private) do
    packages =
      Enum.map(packages, fn {name, versions} ->
        %{name: name, versions: versions, retired: []}
      end)

    :hex_registry.build_versions(%{repository: "hexpm", packages: packages}, private)
  end

  # Answers `/names` and `/versions` from whatever the test built, so the
  # module's own two-request sequence is what drives the decode. The module
  # under test runs in the test process, so the canned bodies live in its
  # process dictionary and the stub needs no state of its own.
  defmodule Client do
    def get(url, _opts) do
      case Process.get({:body, URI.parse(url).path}) do
        {:error, _reason} = error -> error
        {:status, status} -> {:ok, %{status: status, body: ""}}
        body when is_binary(body) -> {:ok, %{status: 200, body: body}}
        nil -> {:ok, %{status: 404, body: ""}}
      end
    end
  end

  defp snapshot(names, versions, context) do
    Process.put({:body, "/names"}, names)
    Process.put({:body, "/versions"}, versions)

    HexRegistry.snapshot(client: Client, public_key: context.public)
  end

  describe "snapshot/1" do
    test "joins a name's timestamp to its newest version", context do
      names = names_resource([{"phoenix", 1_789_378_798}], context.private)
      versions = versions_resource([{"phoenix", ["1.8.12", "1.8.13", "1.8.14"]}], context.private)

      assert {:ok, entries} = snapshot(names, versions, context)

      assert entries == [
               %{
                 name: "phoenix",
                 latest_version: "1.8.14",
                 updated_at: ~U[2026-09-14 09:39:58Z]
               }
             ]
    end

    # `/versions` lists releases in ascending semver order, so the newest is the
    # last one -- not the largest string, which would pick "1.9.0" over "1.10.0".
    test "takes the last version rather than the largest string", context do
      names = names_resource([{"pkg", 0}], context.private)
      versions = versions_resource([{"pkg", ["1.9.0", "1.10.0"]}], context.private)

      assert {:ok, [%{latest_version: "1.10.0"}]} = snapshot(names, versions, context)
    end

    # `updated_at` is optional in the schema. An invented timestamp would order
    # the package wrongly for callers that queue oldest-first, so the absence
    # has to survive as an absence.
    test "reports a missing timestamp as nil rather than inventing one", context do
      names = names_resource(["pkg"], context.private)
      versions = versions_resource([{"pkg", ["1.0.0"]}], context.private)

      assert {:ok, [%{name: "pkg", updated_at: nil}]} = snapshot(names, versions, context)
    end

    # The two resources are independent documents fetched a moment apart, so
    # they can disagree. A package in one and not the other must not crash the
    # join or produce a half-built entry.
    test "drops a package with no versions and tolerates one with no name entry", context do
      names = names_resource([{"only_in_names", 100}, {"in_both", 200}], context.private)

      versions =
        versions_resource(
          [{"in_both", ["1.0.0"]}, {"only_in_versions", ["2.0.0"]}],
          context.private
        )

      assert {:ok, entries} = snapshot(names, versions, context)

      assert Enum.sort_by(entries, & &1.name) == [
               %{name: "in_both", latest_version: "1.0.0", updated_at: ~U[1970-01-01 00:03:20Z]},
               %{name: "only_in_versions", latest_version: "2.0.0", updated_at: nil}
             ]
    end

    test "decodes a registry of many packages", context do
      packages = for n <- 1..500, do: "pkg#{n}"
      names = names_resource(Enum.map(packages, &{&1, 1_789_000_000}), context.private)
      versions = versions_resource(Enum.map(packages, &{&1, ["1.0.0"]}), context.private)

      assert {:ok, entries} = snapshot(names, versions, context)
      assert length(entries) == 500
    end
  end

  describe "snapshot/1 failures" do
    test "an HTTP error on either resource is reported, not partially decoded", context do
      names = names_resource([{"pkg", 0}], context.private)
      versions = versions_resource([{"pkg", ["1.0.0"]}], context.private)

      assert {:error, :hex_registry_unavailable} =
               snapshot({:status, 503}, versions, context)

      assert {:error, :hex_registry_unavailable} =
               snapshot(names, {:status, 500}, context)
    end

    test "a transport failure is reported", context do
      assert {:error, :hex_registry_unavailable} =
               snapshot({:error, :timeout}, "", context)
    end

    # A truncated or corrupted CDN response raises out of `:zlib` rather than
    # returning an error tuple, which is why the decode is wrapped. Crashing
    # here would fail the whole check over a blip the next tick would fix.
    test "a body that is not gzip is an error rather than a raise", context do
      versions = versions_resource([{"pkg", ["1.0.0"]}], context.private)

      assert {:error, :hex_registry_undecodable} =
               snapshot("not gzip at all", versions, context)
    end

    # The signature is the only thing separating the real registry from
    # anything that can answer on that hostname, so a payload signed by the
    # wrong key must not decode.
    test "a resource signed by the wrong key is rejected", context do
      other = :public_key.generate_key({:rsa, 2048, 65_537})
      names = names_resource([{"pkg", 0}], other)
      versions = versions_resource([{"pkg", ["1.0.0"]}], context.private)

      assert {:error, :hex_registry_undecodable} = snapshot(names, versions, context)
    end
  end
end
