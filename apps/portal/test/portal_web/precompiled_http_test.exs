defmodule PortalWeb.PrecompiledHTTPTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  alias PortalWeb.PrecompiledHTTP

  @bytes ~s({"a":1})
  @sha Base.encode16(:crypto.hash(:sha256, @bytes), case: :lower)
  @etag ~s("#{@sha}")

  defp req(inm \\ nil) do
    conn = conn(:get, "/")
    if inm, do: put_req_header(conn, "if-none-match", inm), else: conn
  end

  test "etag is the quoted lowercase sha256 of the bytes" do
    assert PrecompiledHTTP.etag(@bytes) == @etag
    assert PrecompiledHTTP.quote_sha(@sha) == @etag
  end

  test "quote_sha refuses anything that is not a 64-hex sha256" do
    for bad <- [
          "",
          "not-a-sha",
          String.duplicate("a", 63),
          String.duplicate("a", 65),
          @sha <> "Z"
        ] do
      assert_raise ArgumentError, fn -> PrecompiledHTTP.quote_sha(bad) end
    end
  end

  test "the four cache policies" do
    assert PrecompiledHTTP.cache_control(:immutable) == "public, max-age=31536000, immutable"
    assert PrecompiledHTTP.cache_control(:revalidate) == "public, max-age=60, must-revalidate"
    assert PrecompiledHTTP.cache_control(:private_short) == "private, max-age=60"
    assert PrecompiledHTTP.cache_control(:no_store) == "no-store"
  end

  test "no If-None-Match: 200 with the bytes, etag and cache-control" do
    conn = PrecompiledHTTP.send_bytes(req(), @bytes, @etag, :revalidate)
    assert conn.status == 200
    assert conn.resp_body == @bytes
    assert get_resp_header(conn, "etag") == [@etag]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=60, must-revalidate"]
    assert [ct] = get_resp_header(conn, "content-type")
    assert ct =~ "application/json"
  end

  for inm <- [
        ~s("SHA"),
        ~s(W/"SHA"),
        ~s("other", "SHA"),
        ~s("other",W/"SHA"),
        "*"
      ] do
    test "If-None-Match #{inm} answers 304 with no body" do
      inm = String.replace(unquote(inm), "SHA", @sha)
      conn = PrecompiledHTTP.send_bytes(req(inm), @bytes, @etag, :immutable)
      assert conn.status == 304
      assert conn.resp_body == ""
      assert get_resp_header(conn, "etag") == [@etag]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    end
  end

  for inm <- [~s("batch-41"), ~s("deadbeef"), "", ~s(W/"x")] do
    test "If-None-Match #{inspect(inm)} that names other bytes answers 200" do
      conn = PrecompiledHTTP.send_bytes(req(unquote(inm)), @bytes, @etag, :revalidate)
      assert conn.status == 200
      assert conn.resp_body == @bytes
    end
  end

  test "no_store marks a response uncacheable" do
    assert req() |> PrecompiledHTTP.no_store() |> get_resp_header("cache-control") == ["no-store"]
  end
end
