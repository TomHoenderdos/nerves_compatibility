defmodule Portal.Test.FakeS3Test do
  use ExUnit.Case, async: true

  alias Portal.Test.FakeS3
  alias Portal.Test.FakeS3.SigV4

  @empty "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  # AWS SigV4 test suite, get-vanilla.
  test "signs the get-vanilla vector" do
    sig =
      SigV4.signature(%{
        method: "GET",
        path: "/",
        query: [],
        headers: [{"host", "example.amazonaws.com"}, {"x-amz-date", "20150830T123600Z"}],
        payload_hash: @empty,
        amz_date: "20150830T123600Z",
        region: "us-east-1",
        service: "service",
        secret_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
      })

    assert sig == "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
  end

  # Amazon S3 API reference, "Signature Calculations ... Examples", GET object.
  test "signs the S3 GET object example" do
    sig =
      SigV4.signature(%{
        method: "GET",
        path: "/test.txt",
        query: [],
        headers: [
          {"host", "examplebucket.s3.amazonaws.com"},
          {"range", "bytes=0-9"},
          {"x-amz-content-sha256", @empty},
          {"x-amz-date", "20130524T000000Z"}
        ],
        payload_hash: @empty,
        amz_date: "20130524T000000Z",
        region: "us-east-1",
        service: "s3",
        secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      })

    assert sig == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
  end

  defp sigv4(s),
    do: [
      access_key_id: s.access_key,
      secret_access_key: s.secret_key,
      service: :s3,
      region: s.region
    ]

  defp url(s, key \\ ""), do: "#{s.endpoint}/#{s.bucket}#{key}"

  test "the stub refuses an unsigned request and serves a signed round trip" do
    {:ok, s} = FakeS3.start()
    sigv4 = sigv4(s)
    assert {:ok, %{status: 403}} = Req.get(url(s, "/x"), retry: false)

    assert {:ok, %{status: 200}} =
             Req.put(url(s, "/a/b.tar.gz"),
               body: "hello",
               headers: [{"x-amz-meta-sha256", "abc"}],
               aws_sigv4: sigv4,
               retry: false
             )

    assert {:ok, %{status: 200, body: "hello"} = resp} =
             Req.get(url(s, "/a/b.tar.gz"), aws_sigv4: sigv4, retry: false)

    assert Req.Response.get_header(resp, "x-amz-meta-sha256") == ["abc"]
    assert {:ok, %{status: 200}} = Req.head(url(s, "/a/b.tar.gz"), aws_sigv4: sigv4, retry: false)
    assert {:ok, %{status: 404}} = Req.get(url(s, "/missing"), aws_sigv4: sigv4, retry: false)

    assert {:ok, %{status: 200, body: body}} =
             Req.get(url(s),
               params: [{"list-type", "2"}, {"prefix", "a/"}],
               aws_sigv4: sigv4,
               retry: false
             )

    assert body =~ "<Key>a/b.tar.gz</Key>"
    assert body =~ "<Size>5</Size>"
    wrong = Keyword.put(sigv4, :secret_access_key, "nope")
    assert {:ok, %{status: 403}} = Req.get(url(s, "/a/b.tar.gz"), aws_sigv4: wrong, retry: false)
  end

  test "start returns an L2 config and the helpers see the same state" do
    {:ok, s} = FakeS3.start()

    assert %Portal.BuildCache.L2.Config{
             endpoint: endpoint,
             bucket: "ncc-test",
             region: "garage",
             access_key: "GKTEST",
             secret_key: "secret-test",
             read_only?: false
           } = s.config

    assert endpoint == s.endpoint
    FakeS3.put_object(s, "k/1", "body", %{"x-amz-meta-sha256" => "h"})
    assert FakeS3.objects(s) == ["k/1"]

    assert {:ok, %{body: "body", meta: %{"x-amz-meta-sha256" => "h"}}} =
             FakeS3.get_object(s, "k/1")

    FakeS3.delete_object(s, "k/1")
    assert FakeS3.get_object(s, "k/1") == :error
  end

  test "listing pages with continuation tokens and the no_token fault" do
    {:ok, s} = FakeS3.start()
    for k <- ~w(p/a p/b p/c q/z), do: FakeS3.put_object(s, k, k)
    sig = sigv4(s)

    page = fn params ->
      {:ok, %{status: 200, body: b}} =
        Req.get(url(s), params: [{"list-type", "2"} | params], aws_sigv4: sig, retry: false)

      b
    end

    b1 = page.([{"prefix", "p/"}, {"max-keys", "2"}])
    assert b1 =~ "<IsTruncated>true</IsTruncated>"
    assert b1 =~ "<Key>p/a</Key>" and b1 =~ "<Key>p/b</Key>"
    refute b1 =~ "<Key>p/c</Key>"
    assert [_, token] = Regex.run(~r{<NextContinuationToken>(.*)</NextContinuationToken>}, b1)

    b2 = page.([{"prefix", "p/"}, {"max-keys", "2"}, {"continuation-token", token}])
    assert b2 =~ "<Key>p/c</Key>"
    assert b2 =~ "<IsTruncated>false</IsTruncated>"

    FakeS3.set_fault(s, {:list, :no_token})
    b3 = page.([{"prefix", "p/"}])
    assert b3 =~ "<IsTruncated>true</IsTruncated>"
    refute b3 =~ "NextContinuationToken"

    FakeS3.set_fault(s, {:list, :status, 500})

    assert {:ok, %{status: 500}} =
             Req.get(url(s), params: [{"list-type", "2"}], aws_sigv4: sig, retry: false)

    assert {"GET", _, "list-type=2&prefix=p%2F&max-keys=2"} = hd(FakeS3.requests(s))
  end

  test "get and put faults, on_get and the request log" do
    {:ok, s} = FakeS3.start()
    sig = sigv4(s)
    FakeS3.put_object(s, "obj", "0123456789")

    FakeS3.set_fault(s, {:get, :truncate})

    assert {:ok, %{status: 200, body: "01234"}} =
             Req.get(url(s, "/obj"), aws_sigv4: sig, retry: false)

    FakeS3.set_fault(s, {:get, :status, 500})
    assert {:ok, %{status: 500}} = Req.get(url(s, "/obj"), aws_sigv4: sig, retry: false)

    FakeS3.set_fault(s, {:put, :status, 503})
    assert {:ok, %{status: 503}} = Req.put(url(s, "/n"), body: "x", aws_sigv4: sig, retry: false)
    assert FakeS3.objects(s) == ["obj"]

    FakeS3.set_fault(s, nil)
    test_pid = self()
    FakeS3.on_get(s, fn key -> send(test_pid, {:got, key}) end)

    assert {:ok, %{status: 200, body: "0123456789"}} =
             Req.get(url(s, "/obj"), aws_sigv4: sig, retry: false)

    assert_received {:got, "obj"}
    assert {"GET", "/ncc-test/obj", ""} = List.last(FakeS3.requests(s))
  end
end
