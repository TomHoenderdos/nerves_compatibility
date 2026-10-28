defmodule Portal.HexDepsTest do
  @moduledoc """
  Tests for `Portal.HexDeps`.

  Fixtures are real registry package resources built with
  `:hex_registry.build_package/2` and signed with a key generated here, so the
  gzip, signature check and protobuf decode are exercised exactly as against
  `repo.hex.pm`. See `Portal.HexRegistryTest` for the same approach.
  """

  use ExUnit.Case, async: false

  alias Portal.HexDeps

  # Several tests exercise failure paths that log a warning by design.
  @moduletag :capture_log

  setup_all do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    %{private: private, public: public}
  end

  setup do
    HexDeps.flush()
    :ok
  end

  defmodule Client do
    def get(url, _opts) do
      send(self(), {:fetched, URI.parse(url).path})

      case Process.get({:body, URI.parse(url).path}) do
        {:error, _reason} = error -> error
        {:status, status} -> {:ok, %{status: status, body: ""}}
        body when is_binary(body) -> {:ok, %{status: 200, body: body}}
        nil -> {:ok, %{status: 404, body: ""}}
      end
    end
  end

  defp resource(name, releases, private) do
    releases =
      Enum.map(releases, fn {version, deps, extra} ->
        Map.merge(
          %{version: version, inner_checksum: <<0::256>>, dependencies: deps},
          extra
        )
      end)

    :hex_registry.build_package(
      %{name: name, repository: "hexpm", releases: releases},
      private
    )
  end

  defp serve(name, body), do: Process.put({:body, "/packages/#{name}"}, body)

  defp releases(name, context, opts \\ []) do
    HexDeps.releases(name, [client: Client, public_key: context.public] ++ opts)
  end

  test "decodes releases, dependencies and retirement", context do
    serve(
      "tortoise",
      resource(
        "tortoise",
        [
          {"0.9.0", [], %{retired: %{reason: :RETIRED_SECURITY}}},
          {"0.10.0",
           [
             %{package: "gen_state_machine", requirement: "~> 2.0"},
             %{package: "telemetry", requirement: "~> 1.0", optional: true, repository: "hexpm"}
           ], %{}}
        ],
        context.private
      )
    )

    assert {:ok, [old, new]} = releases("tortoise", context)
    assert old == %{version: "0.9.0", retired?: true, deps: [], outer_checksum: nil}
    assert new.version == "0.10.0"
    refute new.retired?

    assert new.deps == [
             %{
               package: "gen_state_machine",
               requirement: "~> 2.0",
               optional: false,
               repository: "hexpm"
             },
             %{package: "telemetry", requirement: "~> 1.0", optional: true, repository: "hexpm"}
           ]
  end

  test "a signature from another key is undecodable", context do
    other = :public_key.generate_key({:rsa, 2048, 65_537})
    serve("jason", resource("jason", [{"1.4.4", [], %{}}], other))
    assert releases("jason", context) == {:error, :hex_registry_undecodable}
  end

  test "garbage bytes are undecodable, not a crash", context do
    serve("jason", "not gzip")
    assert releases("jason", context) == {:error, :hex_registry_undecodable}
  end

  test "a 404 is not_found", context do
    assert releases("nope", context) == {:error, :not_found}
  end

  test "HTTP 5xx and transport errors are unavailable", context do
    serve("jason", {:status, 503})
    assert releases("jason", context) == {:error, :hex_registry_unavailable}

    serve("jason", {:error, :timeout})
    assert releases("jason", context) == {:error, :hex_registry_unavailable}
  end

  test "a second call is served from the cache", context do
    serve("jason", resource("jason", [{"1.4.4", [], %{}}], context.private))
    assert {:ok, _} = releases("jason", context)
    assert_received {:fetched, "/packages/jason"}

    assert {:ok, _} = releases("jason", context)
    refute_received {:fetched, "/packages/jason"}
  end

  test "errors are not cached", context do
    serve("jason", {:status, 503})
    assert {:error, :hex_registry_unavailable} = releases("jason", context)

    serve("jason", resource("jason", [{"1.4.4", [], %{}}], context.private))
    assert {:ok, [_]} = releases("jason", context)
  end

  test "cache: false always fetches", context do
    serve("jason", resource("jason", [{"1.4.4", [], %{}}], context.private))
    assert {:ok, _} = releases("jason", context, cache: false)
    assert {:ok, _} = releases("jason", context, cache: false)
    assert_received {:fetched, "/packages/jason"}
    assert_received {:fetched, "/packages/jason"}
  end

  describe "outer_checksum/3" do
    defp checksum(name, version, context, opts \\ []) do
      HexDeps.outer_checksum(name, version, [client: Client, public_key: context.public] ++ opts)
    end

    @outer :crypto.hash(:sha256, "jason 1.4.4 tarball")

    test "the signed registry's outer checksum, in lowercase hex", context do
      serve(
        "jason",
        resource("jason", [{"1.4.4", [], %{outer_checksum: @outer}}], context.private)
      )

      assert checksum("jason", "1.4.4", context) == {:ok, Base.encode16(@outer, case: :lower)}

      # Served from the cache: a cold Hex cache asks once per package.
      assert checksum("jason", "1.4.4", context) == {:ok, Base.encode16(@outer, case: :lower)}
      assert_received {:fetched, "/packages/jason"}
      refute_received {:fetched, "/packages/jason"}
    end

    test "a version the cached resource lacks is asked about once more", context do
      serve(
        "jason",
        resource("jason", [{"1.4.3", [], %{outer_checksum: @outer}}], context.private)
      )

      assert {:ok, _} = checksum("jason", "1.4.3", context)

      serve(
        "jason",
        resource(
          "jason",
          [{"1.4.3", [], %{outer_checksum: @outer}}, {"1.4.4", [], %{outer_checksum: @outer}}],
          context.private
        )
      )

      assert {:ok, _} = checksum("jason", "1.4.4", context)
      assert checksum("jason", "9.9.9", context) == {:error, :unknown_release}
    end

    test "an unknown package or a release without a checksum is unknown", context do
      assert checksum("nope", "1.0.0", context) == {:error, :unknown_release}

      serve("jason", resource("jason", [{"1.4.4", [], %{}}], context.private))
      assert checksum("jason", "1.4.4", context) == {:error, :unknown_release}
    end

    # A rate limit, an outage or a bad signature means try a later build,
    # never "this tarball is wrong", and nothing of it is remembered.
    test "a 429, a 5xx or a bad signature is unavailable and not cached", context do
      serve("jason", {:status, 429})
      assert checksum("jason", "1.4.4", context) == {:error, :hex_registry_unavailable}

      other = :public_key.generate_key({:rsa, 2048, 65_537})
      serve("jason", resource("jason", [{"1.4.4", [], %{outer_checksum: @outer}}], other))
      assert checksum("jason", "1.4.4", context) == {:error, :hex_registry_unavailable}

      serve(
        "jason",
        resource("jason", [{"1.4.4", [], %{outer_checksum: @outer}}], context.private)
      )

      assert {:ok, _} = checksum("jason", "1.4.4", context)
    end
  end

  # Reads skip an expired row but never remove it; the periodic sweep does.
  # Rows are inserted directly because an expired one cannot be produced
  # through `releases/2` without waiting out the TTL.
  test "the sweep removes expired entries and keeps fresh ones" do
    now = System.system_time(:second)
    :ets.insert(HexDeps, {"stale", [], now - 1})
    :ets.insert(HexDeps, {"fresh", [], now + 3600})

    pid = Process.whereis(HexDeps)
    send(pid, :sweep)
    # A synchronous call behind the message guarantees it has been handled.
    :sys.get_state(pid)

    assert :ets.lookup(HexDeps, "stale") == []
    assert [{"fresh", [], _}] = :ets.lookup(HexDeps, "fresh")
  end
end
