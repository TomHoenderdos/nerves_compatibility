defmodule Portal.Workers.ProgressTest do
  use Portal.DataCase, async: false

  import ExUnit.CaptureLog

  alias Portal.Workers.Progress

  setup do
    previous = Application.get_env(:portal, :progress_mark_backoff_ms)
    Application.put_env(:portal, :progress_mark_backoff_ms, 0)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:portal, :progress_mark_backoff_ms)
        value -> Application.put_env(:portal, :progress_mark_backoff_ms, value)
      end
    end)

    :ok
  end

  test "no-op without a request behind the build" do
    assert Progress.mark(nil, :built) == :ok
  end

  test "retries a failing write, then gives up loudly rather than failing the job" do
    # A lost write here strands the row in a non-terminal status, where
    # `open_request_for_package/1` matches it forever and no later request for
    # that package is ever scanned. Retry, but never fail the caller: the ingest
    # that got us here has already committed its run.
    log =
      capture_log(fn ->
        assert Progress.mark(Ecto.UUID.generate(), :built) == :ok
      end)

    assert log =~ "attempt 1/4"
    assert log =~ "attempt 3/4"
    assert log =~ "Gave up marking request"
    assert log =~ "stranded in a non-terminal status"
  end
end
