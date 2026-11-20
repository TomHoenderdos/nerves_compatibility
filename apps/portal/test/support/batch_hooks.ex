defmodule Portal.BatchHooks do
  @moduledoc """
  Helpers for tests of `Portal.Precompiled.Batches`: a signing key, and a
  setting turned on after a batch's first fingerprint read and off again
  once its renders have read it, so the batch's two fingerprint reads see the
  same value while its renders saw the other.
  """

  import ExUnit.Callbacks

  alias Portal.Precompiled.Keys

  @doc "Configures a fresh signing key under `dir` for the test."
  def signing_key!(dir) do
    old = Application.get_env(:portal, :precompiled_signing)
    on_exit(fn -> Application.put_env(:portal, :precompiled_signing, old) end)
    path = Path.join(dir, "signing.key")
    Keys.write!(path, Keys.generate())
    Application.put_env(:portal, :precompiled_signing, key_path: path)
  end

  @doc """
  How many times a render of `name` reads the settings now, from a process
  of its own as a batch's lane is.
  """
  def settings_reads(name) do
    counter = :counters.new(1, [])
    id = {__MODULE__, make_ref()}

    task =
      Task.async(fn ->
        receive do
          :go -> Portal.Precompiled.Manifests.render_both(name)
        end
      end)

    pid = task.pid

    :ok =
      :telemetry.attach(
        id,
        [:portal, :repo, :query],
        fn _event, _measurements, meta, _ ->
          if self() == pid and meta[:source] == "settings", do: :counters.add(counter, 1, 1)
        end,
        nil
      )

    try do
      send(pid, :go)
      Task.await(task, :infinity)
      :counters.get(counter, 1)
    after
      :telemetry.detach(id)
    end
  end

  @doc """
  Runs `on` in the calling process right after the next fingerprint read it
  makes, and `off` in a batch's lane right after that lane's `reads`-th read
  of the settings (`settings_reads/1`), once each. `flipped?/1` of the
  returned hook says whether both ran.
  """
  def flip_during_render(on, off, reads) when reads > 0 do
    me = self()
    # 1: state (0 waiting, 1 turned on, 2 turned off); 2: lane settings reads.
    hook = :atomics.new(2, [])
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:portal, :repo, :query],
        fn _event, _measurements, meta, _ ->
          cond do
            self() == me and meta.query =~ "WITH runs AS" and
                :atomics.compare_exchange(hook, 1, 0, 1) == :ok ->
              {:ok, _} = on.()

            me in Process.get(:"$callers", []) and meta[:source] == "settings" and
              :atomics.get(hook, 1) == 1 and :atomics.add_get(hook, 2, 1) == reads ->
              {:ok, _} = off.()
              :atomics.put(hook, 1, 2)

            true ->
              :ok
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
    hook
  end

  @doc "Whether the hook of `flip_during_render/3` turned the setting on and off again."
  def flipped?(hook), do: :atomics.get(hook, 1) == 2
end
