defmodule Portal.Oban.OwnedAckEngineTest do
  # A build whose `docker kill` hung returned fifteen hours late, long after
  # Lifeline had rescued its row and a later attempt had discarded it, and
  # its ack turned the discarded job back into a retryable one (available at
  # attempt 3/3 with discarded_at set). An ack writes only while the row is
  # still executing under the attempt that acks it.
  use Portal.DataCase, async: false

  @moduletag :capture_log

  alias Portal.Oban.OwnedAckEngine, as: Engine
  alias Portal.Repo

  @mine ["portal@builder-a", "11111111-1111-1111-1111-111111111111"]
  @theirs ["portal@builder-b", "22222222-2222-2222-2222-222222222222"]

  defp conf, do: Oban.Config.new(repo: Repo, engine: Engine, testing: :manual)

  defp row(state, attempted_by, attempt \\ 2) do
    Repo.insert!(%Oban.Job{
      worker: "Portal.Workers.Build",
      queue: "builds",
      state: state,
      args: %{},
      attempt: attempt,
      max_attempts: 3,
      attempted_at: DateTime.utc_now(),
      attempted_by: attempted_by,
      errors: []
    })
  end

  # What the executor acks with: the job as this attempt fetched it.
  defp attempt(row, attempted_by),
    do: %{
      row
      | attempted_by: attempted_by,
        unsaved_error: %{kind: :error, reason: "late", stacktrace: []}
    }

  defp reload(row), do: Repo.get!(Oban.Job, row.id)

  describe "the attempt that still owns its row" do
    test "completes it" do
      job = row("executing", @mine)
      assert :ok = Engine.complete_job(conf(), attempt(job, @mine))
      assert reload(job).state == "completed"
    end

    test "errors it" do
      job = row("executing", @mine)
      assert :ok = Engine.error_job(conf(), attempt(job, @mine), 60)
      assert %{state: "retryable", errors: [_]} = reload(job)
    end

    test "discards, snoozes and cancels it" do
      for {ack, state} <- [
            {&Engine.discard_job(&1, &2), "discarded"},
            {&Engine.snooze_job(&1, &2, 60), "scheduled"},
            {&Engine.cancel_job(&1, &2), "cancelled"}
          ] do
        job = row("executing", @mine)
        assert :ok = ack.(conf(), attempt(job, @mine))
        assert reload(job).state == state
      end
    end
  end

  describe "a late attempt" do
    test "does not touch a row a later attempt discarded" do
      job = row("discarded", @theirs, 3)
      discarded = reload(job)

      for ack <- [
            &Engine.complete_job(&1, &2),
            &Engine.error_job(&1, &2, 60),
            &Engine.discard_job(&1, &2),
            &Engine.snooze_job(&1, &2, 60),
            &Engine.cancel_job(&1, &2)
          ] do
        assert :ok = ack.(conf(), attempt(%{job | attempt: 2}, @mine))
        assert reload(job) == discarded
      end
    end

    test "does not touch a row rescued and executing elsewhere" do
      job = row("executing", @theirs, 3)
      before = reload(job)
      assert :ok = Engine.error_job(conf(), attempt(%{job | attempt: 2}, @mine), 60)
      assert reload(job) == before
    end

    # Lifeline's rescue leaves attempted_by as it was, so this same producer
    # can fetch the row again with an identical attempted_by; only the
    # attempt number tells the two attempts apart.
    test "does not touch a row this producer re-fetched as a later attempt" do
      job = row("executing", @mine, 3)
      before = reload(job)

      for ack <- [
            &Engine.complete_job(&1, &2),
            &Engine.error_job(&1, &2, 60),
            &Engine.discard_job(&1, &2),
            &Engine.snooze_job(&1, &2, 60),
            &Engine.cancel_job(&1, &2)
          ] do
        assert :ok = ack.(conf(), attempt(%{job | attempt: 2}, @mine))
        assert reload(job) == before
      end
    end

    test "does not touch a row rescued back to available" do
      job = row("available", @mine)
      assert :ok = Engine.complete_job(conf(), attempt(job, @mine))
      assert reload(job).state == "available"
    end
  end

  # The five acks above are every write the executor makes for an attempt.
  # An Oban upgrade that adds an engine callback fails this pin, so a new
  # ack cannot bypass the ownership check unnoticed.
  test "the engine behaviour has exactly the callbacks this engine was written against" do
    assert Enum.sort(Oban.Engine.behaviour_info(:callbacks)) ==
             Enum.sort(
               init: 2,
               put_meta: 4,
               check_meta: 3,
               refresh: 2,
               shutdown: 2,
               insert_job: 3,
               insert_job: 5,
               insert_all_jobs: 3,
               insert_all_jobs: 5,
               stage_jobs: 3,
               fetch_jobs: 3,
               prune_jobs: 3,
               rescue_jobs: 3,
               check_available: 1,
               complete_job: 2,
               discard_job: 2,
               error_job: 3,
               snooze_job: 3,
               cancel_job: 2,
               cancel_all_jobs: 2,
               delete_job: 2,
               delete_all_jobs: 2,
               retry_job: 2,
               retry_all_jobs: 2,
               update_job: 3
             )
  end

  test "is the engine the portal's Oban runs" do
    assert Application.get_env(:portal, Oban)[:engine] == Engine
  end
end
