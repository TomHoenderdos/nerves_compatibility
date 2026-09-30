defmodule Portal.NativeClosureCacheTest do
  @moduledoc """
  `Portal.NativeClosure` against the shared `Portal.HexDeps` cache.

  Separate from `Portal.NativeClosureTest`, which is async and runs uncached:
  these tests need the real, node-wide table and flush it (and one raises the
  global log level), so they cannot run alongside anything else.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 2]

  alias Portal.HexDeps
  alias Portal.NativeClosure

  setup_all do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    %{private: private, public: public}
  end

  setup do
    HexDeps.flush()
    on_exit(&HexDeps.flush/0)
    :ok
  end

  defmodule Client do
    def get(url, _opts) do
      path = URI.parse(url).path
      send(self(), {:fetched, path})

      case Process.get({:body, path}) do
        body when is_binary(body) -> {:ok, %{status: 200, body: body}}
        nil -> {:ok, %{status: 404, body: ""}}
      end
    end
  end

  defp serve(name, releases, context) do
    releases =
      Enum.map(releases, fn {version, deps} ->
        %{
          version: version,
          inner_checksum: <<0::256>>,
          dependencies: Enum.map(deps, fn {dep, req} -> %{package: dep, requirement: req} end)
        }
      end)

    body =
      :hex_registry.build_package(
        %{name: name, repository: "hexpm", releases: releases},
        context.private
      )

    Process.put({:body, "/packages/#{name}"}, body)
  end

  defp classify(name, version, context) do
    NativeClosure.classify(name, version, client: Client, public_key: context.public)
  end

  # `Portal.Workers.UpdateCheck` hands over a release it has only just seen. A
  # root resource cached before that release existed would not list it, and
  # the package would be sent to Docker as `{:unknown_version, ...}`.
  test "the root package is fetched fresh while dependencies use the cache", context do
    serve("root", [{"1.0.0", [{"lib", "~> 1.0"}]}], context)
    serve("lib", [{"1.0.0", []}], context)

    assert classify("root", "1.0.0", context) == :pure
    assert_received {:fetched, "/packages/root"}
    assert_received {:fetched, "/packages/lib"}

    serve("root", [{"1.0.0", [{"lib", "~> 1.0"}]}, {"1.1.0", [{"lib", "~> 1.0"}]}], context)

    assert classify("root", "1.1.0", context) == :pure
    assert_received {:fetched, "/packages/root"}
    refute_received {:fetched, "/packages/lib"}
  end

  # A full run is ~18.5k names and tens of minutes; it has to show it is alive.
  # The suite logs at :warning, so the level is raised for this test only.
  test "dry_run logs running counts every 500 names", context do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    names = for i <- 1..1_000, do: "gone#{i}"

    log =
      capture_log([level: :info], fn ->
        NativeClosure.dry_run(names, client: Client, public_key: context.public, cache: false)
      end)

    assert log =~ "NativeClosure.dry_run: 500 classified (pure 0, native 500, errors 0)"
    assert log =~ "NativeClosure.dry_run: 1000 classified (pure 0, native 1000, errors 0)"
  end
end
