defmodule Portal.NativeClosureTest do
  @moduledoc """
  Tests for `Portal.NativeClosure` against locally signed registry resources.
  `cache: false` keeps each test's fake registry from leaking into the next.
  """

  use ExUnit.Case, async: true

  alias Portal.NativeClosure

  setup_all do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    %{private: private, public: public}
  end

  defmodule Client do
    def get(url, _opts) do
      case Process.get({:body, URI.parse(url).path}) do
        {:status, status} -> {:ok, %{status: status, body: ""}}
        body when is_binary(body) -> {:ok, %{status: 200, body: body}}
        nil -> {:ok, %{status: 404, body: ""}}
      end
    end
  end

  # `packages` is `%{name => [{version, [dep]} | {version, [dep], extra}]}`;
  # a dep is `{name, requirement}` or a full dependency map.
  defp registry(packages, context) do
    for {name, releases} <- packages do
      releases =
        Enum.map(releases, fn
          {version, deps} -> release(version, deps, %{})
          {version, deps, extra} -> release(version, deps, extra)
        end)

      body =
        :hex_registry.build_package(
          %{name: name, repository: "hexpm", releases: releases},
          context.private
        )

      Process.put({:body, "/packages/#{name}"}, body)
    end
  end

  defp release(version, deps, extra) do
    deps =
      Enum.map(deps, fn
        {name, req} -> %{package: name, requirement: req}
        %{} = dep -> dep
      end)

    Map.merge(%{version: version, inner_checksum: <<0::256>>, dependencies: deps}, extra)
  end

  defp classify(name, version, context) do
    NativeClosure.classify(name, version,
      client: Client,
      public_key: context.public,
      cache: false
    )
  end

  test "a closure of pure packages is pure", context do
    registry(
      %{
        "app" => [{"1.0.0", [{"jason", "~> 1.4"}, {"telemetry", "~> 1.0"}]}],
        "jason" => [{"1.4.4", []}],
        "telemetry" => [{"1.3.0", []}]
      },
      context
    )

    assert classify("app", "1.0.0", context) == :pure
  end

  test "a direct marker dependency is native", context do
    registry(%{"app" => [{"1.0.0", [{"elixir_make", "~> 0.8"}]}]}, context)
    assert classify("app", "1.0.0", context) == {:native, {:marker, "elixir_make"}}
  end

  test "a marker three levels down is native", context do
    registry(
      %{
        "app" => [{"1.0.0", [{"a", "~> 1.0"}]}],
        "a" => [{"1.0.0", [{"b", "~> 1.0"}]}],
        "b" => [{"1.0.0", [{"rustler_precompiled", "~> 0.7"}]}]
      },
      context
    )

    assert classify("app", "1.0.0", context) == {:native, {:marker, "rustler_precompiled"}}
  end

  test "an optional marker dependency is ignored", context do
    registry(
      %{
        "app" => [
          {"1.0.0", [%{package: "rustler", requirement: "~> 0.30", optional: true}]}
        ]
      },
      context
    )

    assert classify("app", "1.0.0", context) == :pure
  end

  test "a nerves package or dependency is native", context do
    registry(%{"app" => [{"1.0.0", [{"nerves_runtime", "~> 0.13"}]}]}, context)
    assert classify("app", "1.0.0", context) == {:native, {:nerves, "nerves_runtime"}}
    assert classify("nerves_key", "1.0.0", context) == {:native, {:nerves, "nerves_key"}}
  end

  test "resolves the newest release that satisfies the requirement", context do
    registry(
      %{
        "app" => [{"1.0.0", [{"lib", "~> 1.0"}]}],
        # 2.0.0 would be native, but ~> 1.0 cannot pick it.
        "lib" => [
          {"1.0.0", [{"zigler", "~> 0.1"}]},
          {"1.2.0", []},
          {"2.0.0", [{"zigler", "~> 0.1"}]}
        ]
      },
      context
    )

    assert classify("app", "1.0.0", context) == :pure
  end

  test "skips a retired release when a live one matches, falls back when none does", context do
    registry(
      %{
        "app" => [{"1.0.0", [{"lib", "~> 1.0"}]}],
        "lib" => [
          {"1.0.0", []},
          {"1.1.0", [{"unifex", "~> 1.0"}], %{retired: %{reason: :RETIRED_INVALID}}}
        ],
        "only_retired" => [
          {"1.0.0", [{"bundlex", "~> 1.0"}], %{retired: %{reason: :RETIRED_OTHER}}}
        ],
        "app2" => [{"1.0.0", [{"only_retired", "~> 1.0"}]}]
      },
      context
    )

    assert classify("app", "1.0.0", context) == :pure
    assert classify("app2", "1.0.0", context) == {:native, {:marker, "bundlex"}}
  end

  test "prereleases do not satisfy a plain requirement", context do
    registry(
      %{
        "app" => [{"1.0.0", [{"lib", "~> 1.0"}]}],
        "lib" => [{"1.0.0", []}, {"1.1.0-rc.0", [{"elixir_make", "~> 0.8"}]}],
        "pre" => [{"1.0.0", [{"lib2", "~> 2.0.0-rc.0"}]}],
        "lib2" => [{"2.0.0-rc.1", []}]
      },
      context
    )

    assert classify("app", "1.0.0", context) == :pure
    assert classify("pre", "1.0.0", context) == :pure
  end

  test "a later edge to an already-resolved package still has its requirement checked", context do
    registry(
      %{
        "app" => [{"1.0.0", [{"lib", ">= 1.0.0"}, {"foo", "~> 1.0"}]}],
        "foo" => [{"1.0.0", [{"lib", "~> 1.0"}]}],
        # `lib`'s first edge (`>= 1.0.0`) resolves to 2.0.0, which is pure; if
        # that resolution were reused unchecked for `foo`'s `~> 1.0` edge, this
        # closure would come back :pure even though Mix would pick 1.x for
        # that edge, and 1.x depends on a marker.
        "lib" => [{"1.0.0", [{"elixir_make", "~> 0.8"}]}, {"2.0.0", []}]
      },
      context
    )

    assert classify("app", "1.0.0", context) == {:native, {:unsatisfiable, "lib", "~> 1.0"}}
  end

  test "cycles terminate", context do
    registry(
      %{
        "a" => [{"1.0.0", [{"b", "~> 1.0"}]}],
        "b" => [{"1.0.0", [{"a", "~> 1.0"}]}]
      },
      context
    )

    assert classify("a", "1.0.0", context) == :pure
  end

  test "unresolvable or unreadable closures fail closed as native", context do
    registry(
      %{
        "unsat" => [{"1.0.0", [{"lib", "~> 9.0"}]}],
        "badreq" => [{"1.0.0", [{"lib", "not a requirement"}]}],
        "other_repo" => [
          {"1.0.0", [%{package: "lib", requirement: "~> 1.0", repository: "acme"}]}
        ],
        "missing_dep" => [{"1.0.0", [{"ghost", "~> 1.0"}]}],
        "lib" => [{"1.0.0", []}]
      },
      context
    )

    assert classify("unsat", "1.0.0", context) == {:native, {:unsatisfiable, "lib", "~> 9.0"}}

    assert classify("badreq", "1.0.0", context) ==
             {:native, {:bad_requirement, "lib", "not a requirement"}}

    assert classify("other_repo", "1.0.0", context) == {:native, {:repository, "lib", "acme"}}

    assert classify("missing_dep", "1.0.0", context) ==
             {:native, {:registry, "ghost", :not_found}}

    assert classify("unsat", "5.0.0", context) == {:native, {:unknown_version, "unsat", "5.0.0"}}
  end

  test "a closure of exactly the size cap is pure", context do
    chain =
      for i <- 0..499, into: %{} do
        {"p#{i}", [{"1.0.0", if(i < 499, do: [{"p#{i + 1}", "~> 1.0"}], else: [])}]}
      end

    registry(chain, context)
    assert classify("p0", "1.0.0", context) == :pure
  end

  test "a closure over the size cap is native", context do
    chain =
      for i <- 0..501, into: %{} do
        {"p#{i}", [{"1.0.0", if(i < 501, do: [{"p#{i + 1}", "~> 1.0"}], else: [])}]}
      end

    registry(chain, context)
    assert classify("p0", "1.0.0", context) == {:native, :closure_too_large}
  end

  @tag :capture_log
  test "an unavailable registry is an error, not a classification", context do
    registry(%{"app" => [{"1.0.0", [{"lib", "~> 1.0"}]}]}, context)
    Process.put({:body, "/packages/lib"}, {:status, 503})

    assert classify("app", "1.0.0", context) == {:error, :hex_registry_unavailable}
  end

  @tag :capture_log
  test "dry_run counts pure, native and errors at each package's newest live release", context do
    registry(
      %{
        "pure" => [{"1.0.0", [{"elixir_make", "~> 0.8"}]}, {"1.1.0", []}],
        "nif" => [{"1.0.0", [{"rustler", "~> 0.30"}]}],
        "down" => [{"1.0.0", [{"lib", "~> 1.0"}]}]
      },
      context
    )

    Process.put({:body, "/packages/lib"}, {:status, 503})

    report =
      NativeClosure.dry_run(["pure", "nif", "down", "gone"],
        client: Client,
        public_key: context.public,
        cache: false
      )

    assert report == %{
             pure: 1,
             native: 2,
             errors: 1,
             reasons: %{marker: 1, registry: 1}
           }
  end
end
