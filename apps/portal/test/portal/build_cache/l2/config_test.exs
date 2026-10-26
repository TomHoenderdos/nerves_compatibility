defmodule Portal.BuildCache.L2.ConfigTest do
  use ExUnit.Case, async: true

  alias Portal.BuildCache.L2.Config

  @full [
    endpoint: "http://100.64.0.2:3900",
    bucket: "ncc-build-cache",
    region: "garage",
    access_key: "GK1",
    secret_key: "s"
  ]

  test "a full config is on" do
    assert {:ok,
            %Config{
              endpoint: "http://100.64.0.2:3900",
              bucket: "ncc-build-cache",
              region: "garage",
              read_only?: false
            }} = Config.config(@full)
  end

  test "no endpoint is off" do
    assert :off = Config.config([])
    assert :off = Config.config(endpoint: "", bucket: "b")
    assert :off = Config.config(endpoint: nil, bucket: "b", access_key: "a", secret_key: "s")
  end

  test "an endpoint with anything missing is an error, not off" do
    assert {:error, msg} = Config.config(Keyword.delete(@full, :bucket))
    assert msg =~ "NCC_BUILD_CACHE_S3_BUCKET"
    assert {:error, _} = Config.config(Keyword.put(@full, :secret_key, ""))
  end

  test "the endpoint must be an http(s) URL with a host and no path" do
    assert {:error, msg} = Config.config(Keyword.put(@full, :endpoint, "100.64.0.2:3900"))
    assert msg =~ "endpoint"

    assert {:error, _} =
             Config.config(Keyword.put(@full, :endpoint, "http://100.64.0.2:3900/bucket"))

    assert {:ok, %Config{endpoint: "https://garage.example"}} =
             Config.config(Keyword.put(@full, :endpoint, "https://garage.example/"))
  end

  test "region defaults to garage and read_only reads the flag" do
    assert {:ok, %Config{region: "garage"}} = Config.config(Keyword.delete(@full, :region))
    assert {:ok, %Config{read_only?: true}} = Config.config(Keyword.put(@full, :read_only, true))
  end

  test "inspecting a config never shows the secret key" do
    {:ok, cfg} = Config.config(Keyword.put(@full, :secret_key, "very-secret-value"))
    refute inspect(cfg) =~ "very-secret-value"
  end

  test "an endpoint with userinfo or a fragment is refused without echoing the userinfo" do
    assert {:error, msg} =
             Config.config(Keyword.put(@full, :endpoint, "http://u:p@100.64.0.2:3900"))

    assert msg =~ "endpoint"
    refute msg =~ "p@"

    assert {:error, _} = Config.config(Keyword.put(@full, :endpoint, "http://host:3900#frag"))
  end

  test "insecure_endpoint? is plain http off loopback and off the private network" do
    for endpoint <- [
          "http://10.0.0.5:3900",
          "http://192.168.1.2",
          "http://100.128.0.1:3900",
          "http://garage.example:3900",
          "http://[2001:db8::1]:3900"
        ] do
      assert Config.insecure_endpoint?(endpoint), endpoint
    end

    for endpoint <- [
          "http://100.64.0.2:3900",
          "http://100.127.255.254",
          "http://127.0.0.1:3900",
          "http://127.8.9.10",
          "http://localhost:3900",
          "http://LOCALHOST",
          "http://[::1]:3900",
          "https://garage.example",
          "https://10.0.0.5:3900"
        ] do
      refute Config.insecure_endpoint?(endpoint), endpoint
    end

    {:ok, cfg} = Config.config(Keyword.put(@full, :endpoint, "http://10.0.0.5:3900"))
    assert Config.insecure_endpoint?(cfg)
  end
end
