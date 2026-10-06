defmodule Portal.HexPackageLookupTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog.Ingestion
  alias Portal.HexPackageLookup

  # Failure paths log a warning by design.
  @moduletag :capture_log

  defmodule Client do
    def get(url, opts) do
      send(self(), {:fetched, URI.parse(url).path, opts})

      case Process.get(:cdn_answer) do
        {:error, _reason} = error -> error
        {:status, status} -> {:ok, %{status: status, body: ""}}
        body when is_binary(body) -> {:ok, %{status: 200, body: body}}
      end
    end
  end

  setup_all do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    %{private: private, public: public}
  end

  defp exists?(name, context),
    do:
      HexPackageLookup.package_exists?(name,
        client: Client,
        public_key: context.public,
        cache: false
      )

  defp signed_package(name, private) do
    :hex_registry.build_package(
      %{
        name: name,
        repository: "hexpm",
        releases: [%{version: "1.0.0", inner_checksum: <<0::256>>, dependencies: []}]
      },
      private
    )
  end

  test "a package the catalog already has exists without asking the CDN", context do
    dir = Path.join(System.tmp_dir!(), "lookup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => "cataloguedpkg", "version" => "1.0.0"},
          "finished_at" => "2026-07-05T10:00:00Z",
          "systems" => %{"nerves_system_rpi0" => %{"status" => "pass"}}
        },
        %{run_id: "cataloguedpkg-1", image_digest: "sha256:x", files_dir: dir, log: "l"}
      )

    assert exists?("cataloguedpkg", context) == {:ok, true}
    refute_received {:fetched, _, _}
  end

  test "a package the CDN serves exists", context do
    Process.put(:cdn_answer, signed_package("cdnpkg", context.private))

    assert exists?("cdnpkg", context) == {:ok, true}
    assert_received {:fetched, "/packages/cdnpkg", _opts}
  end

  test "a 404 or 403 from the CDN means no such package", context do
    Process.put(:cdn_answer, {:status, 404})
    assert exists?("missingpkg", context) == {:ok, false}

    Process.put(:cdn_answer, {:status, 403})
    assert exists?("missingpkg", context) == {:ok, false}
  end

  test "any other answer is unavailable, not absent", context do
    Process.put(:cdn_answer, {:status, 500})
    assert exists?("flakypkg", context) == {:error, :hex_api_unavailable}

    Process.put(:cdn_answer, {:error, %Req.TransportError{reason: :timeout}})
    assert exists?("flakypkg", context) == {:error, :hex_api_unavailable}

    Process.put(:cdn_answer, "not a registry resource")
    assert exists?("flakypkg", context) == {:error, :hex_api_unavailable}
  end

  # Someone is waiting on the form: one slow answer must not hold the request
  # for Req's retry schedule or a 30 s timeout.
  test "the CDN request neither retries nor waits long", context do
    Process.put(:cdn_answer, {:status, 404})

    exists?("quickpkg", context)

    assert_received {:fetched, "/packages/quickpkg", opts}
    assert opts[:retry] == false
    assert opts[:receive_timeout] == 5_000
  end
end
