defmodule NccAgent.HexRegistryTest do
  @moduledoc """
  Fixtures are registry package resources built with
  `:hex_registry.build_package/2` and signed with a key generated here, as in
  `Portal.HexDepsTest`, so the gzip, signature check and decode run exactly
  as against the real repository.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias NccAgent.HexRegistry

  @outer :crypto.hash(:sha256, "jason tarball")

  setup_all do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    %{private: private, public: public}
  end

  setup do
    HexRegistry.flush()
    :ok
  end

  defmodule Client do
    def get(url, opts) do
      path = URI.parse(url).path
      send(self(), {:fetched, path})
      send(self(), {:opts, opts})

      case Process.get({:body, path}) do
        {:error, _reason} = error -> error
        {:status, status} -> {:ok, %{status: status, body: ""}}
        body when is_binary(body) -> {:ok, %{status: 200, body: body}}
        nil -> {:ok, %{status: 404, body: ""}}
      end
    end
  end

  defp serve(name, releases, key) do
    releases = Enum.map(releases, &Map.merge(%{inner_checksum: <<0::256>>, dependencies: []}, &1))

    body =
      :hex_registry.build_package(%{name: name, repository: "hexpm", releases: releases}, key)

    Process.put({:body, "/packages/#{name}"}, body)
  end

  defp checksum(name, version, ctx, opts \\ []),
    do:
      HexRegistry.outer_checksum(
        name,
        version,
        [client: Client, public_key: ctx.public] ++ opts
      )

  test "the signed registry's checksum, once per package", ctx do
    serve("jason", [%{version: "1.4.4", outer_checksum: @outer}], ctx.private)
    hex = Base.encode16(@outer, case: :lower)

    assert checksum("jason", "1.4.4", ctx) == {:ok, hex}
    assert checksum("jason", "1.4.4", ctx) == {:ok, hex}
    assert_received {:fetched, "/packages/jason"}
    refute_received {:fetched, "/packages/jason"}
  end

  test "a version the cached resource lacks is asked about once more", ctx do
    serve("jason", [%{version: "1.4.3", outer_checksum: @outer}], ctx.private)
    assert {:ok, _} = checksum("jason", "1.4.3", ctx)

    serve(
      "jason",
      [%{version: "1.4.3", outer_checksum: @outer}, %{version: "1.4.4", outer_checksum: @outer}],
      ctx.private
    )

    assert {:ok, _} = checksum("jason", "1.4.4", ctx)
    assert checksum("jason", "9.9.9", ctx) == {:error, :unknown_release}
  end

  test "an unknown package or a release without a checksum is unknown", ctx do
    assert checksum("nope", "1.0.0", ctx) == {:error, :unknown_release}

    serve("jason", [%{version: "1.4.4"}], ctx.private)
    assert checksum("jason", "1.4.4", ctx) == {:error, :unknown_release}
  end

  test "a 429, a 5xx, a transport error or a bad signature is unavailable, not cached", ctx do
    for answer <- [{:status, 429}, {:status, 503}, {:error, :timeout}] do
      Process.put({:body, "/packages/jason"}, answer)
      assert checksum("jason", "1.4.4", ctx) == {:error, :hex_registry_unavailable}
    end

    other = :public_key.generate_key({:rsa, 2048, 65_537})
    serve("jason", [%{version: "1.4.4", outer_checksum: @outer}], other)
    assert checksum("jason", "1.4.4", ctx) == {:error, :hex_registry_unavailable}

    serve("jason", [%{version: "1.4.4", outer_checksum: @outer}], ctx.private)
    assert {:ok, _} = checksum("jason", "1.4.4", ctx)
  end

  test "a resource signed by another key is unavailable", ctx do
    other = :public_key.generate_key({:rsa, 2048, 65_537})
    serve("jason", [%{version: "1.4.4", outer_checksum: @outer}], other)
    assert checksum("jason", "1.4.4", ctx) == {:error, :hex_registry_unavailable}
  end

  test "a correctly signed resource for another package name is unavailable", ctx do
    releases = [
      %{version: "1.4.4", outer_checksum: @outer, inner_checksum: <<0::256>>, dependencies: []}
    ]

    body =
      :hex_registry.build_package(
        %{name: "plug", repository: "hexpm", releases: releases},
        ctx.private
      )

    Process.put({:body, "/packages/jason"}, body)

    assert checksum("jason", "1.4.4", ctx) == {:error, :hex_registry_unavailable}
  end

  test "follows no redirect and refuses a body over the cap", ctx do
    serve("jason", [%{version: "1.4.4", outer_checksum: @outer}], ctx.private)

    assert checksum("jason", "1.4.4", ctx, max_bytes: 16) == {:error, :hex_registry_unavailable}
    assert_received {:opts, opts}
    assert opts[:redirect] == false
    assert is_function(opts[:into], 2)
  end

  # Without a sweep every package a builder ever promoted stays resident.
  test "storing an answer sweeps expired rows", ctx do
    :ets.insert(HexRegistry, {"stale", %{}, System.system_time(:second) - 1})
    serve("jason", [%{version: "1.4.4", outer_checksum: @outer}], ctx.private)

    assert {:ok, _} = checksum("jason", "1.4.4", ctx)
    assert :ets.lookup(HexRegistry, "stale") == []
    assert [_] = :ets.lookup(HexRegistry, "jason")
  end
end
