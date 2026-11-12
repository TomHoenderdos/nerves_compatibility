defmodule Portal.Workers.OomRetryTest do
  use ExUnit.Case, async: true

  alias Portal.Workers.OomRetry

  defp error(attempt, message),
    do: %{
      "attempt" => attempt,
      "at" => "2026-11-12T10:00:00Z",
      "error" => "** (Oban.PerformError) Portal.Workers.Build failed with #{message}"
    }

  @oom ~s({:error, "worker/runner exit 137"})
  @other ~s({:error, "worker/runner exit 10"})

  test "the first attempt is never an OOM retry" do
    refute OomRetry.oom_retry?(%Oban.Job{attempt: 1, errors: []})
    refute OomRetry.oom_retry?(%Oban.Job{attempt: 1, errors: [error(1, @oom)]})
  end

  test "a later attempt after an exit 137 is one" do
    assert OomRetry.oom_retry?(%Oban.Job{attempt: 2, errors: [error(1, @oom)]})
  end

  test "a later attempt after any other error is not" do
    refute OomRetry.oom_retry?(%Oban.Job{attempt: 2, errors: [error(1, @other)]})
    refute OomRetry.oom_retry?(%Oban.Job{attempt: 2, errors: []})
  end

  test "only the newest error counts" do
    assert OomRetry.oom_retry?(%Oban.Job{attempt: 3, errors: [error(1, @other), error(2, @oom)]})
    refute OomRetry.oom_retry?(%Oban.Job{attempt: 3, errors: [error(1, @oom), error(2, @other)]})
  end

  test "last_error/1 is the newest error's message, or nil" do
    assert OomRetry.last_error(%Oban.Job{errors: [error(1, @other), error(2, @oom)]}) =~
             "exit 137"

    assert OomRetry.last_error(%Oban.Job{errors: []}) == nil
    assert OomRetry.last_error(%Oban.Job{errors: [%{"attempt" => 1}]}) == nil
  end
end
