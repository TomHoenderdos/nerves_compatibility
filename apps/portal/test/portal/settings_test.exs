defmodule Portal.SettingsTest do
  use Portal.DataCase, async: false

  alias Portal.Settings

  test "get returns the defaults when nothing is stored" do
    setting = Settings.get()
    assert setting.argus_enabled == true
    assert setting.argus_analyses == [:default, :exposure]
    assert setting.argus_scope == :firmware
    assert setting.argus_min_severity == :warning
    assert setting.argus_timeout_seconds == 300
  end

  test "save stores a single row and get reads it back" do
    assert {:ok, _} =
             Settings.save(%{
               argus_enabled: false,
               argus_analyses: ["otp", "security"],
               argus_scope: "all",
               argus_min_severity: "error",
               argus_timeout_seconds: 600
             })

    assert {:ok, _} = Settings.save(%{argus_timeout_seconds: 900})

    setting = Settings.get()
    assert setting.argus_enabled == false
    assert setting.argus_analyses == [:otp, :security]
    assert setting.argus_scope == :all
    assert setting.argus_min_severity == :error
    assert setting.argus_timeout_seconds == 900
    assert Portal.Repo.aggregate("settings", :count) == 1
  end

  test "rejects an unknown analysis" do
    assert {:error, _} = Settings.save(%{argus_analyses: ["default", "not_an_analysis"]})
  end

  test "rejects an empty analysis list" do
    assert {:error, _} = Settings.save(%{argus_analyses: []})
  end

  test "rejects a timeout outside 30..1800" do
    assert {:error, _} = Settings.save(%{argus_timeout_seconds: 29})
    assert {:error, _} = Settings.save(%{argus_timeout_seconds: 1801})
  end

  test "rejects an unknown scope and severity" do
    assert {:error, _} = Settings.save(%{argus_scope: "everything"})
    assert {:error, _} = Settings.save(%{argus_min_severity: "fatal"})
  end

  test "worker_argus is nil when disabled and the worker map otherwise" do
    assert Settings.worker_argus(Settings.get()) == %{
             "analyses" => ["default", "exposure"],
             "scope" => "firmware",
             "timeout_seconds" => 300
           }

    {:ok, _} = Settings.save(%{argus_enabled: false})
    assert Settings.worker_argus(Settings.get()) == nil
  end

  describe "set_remote_auto_on/1" do
    test "writes only remote_auto_on, keeping an admin save that landed before it" do
      assert {:ok, _} = Settings.save(%{remote_mode: :off, remote_backlog_threshold: 4})
      assert {:ok, _} = Settings.set_remote_auto_on(true)

      setting = Settings.get()
      assert setting.remote_mode == :off
      assert setting.remote_backlog_threshold == 4
      assert setting.remote_auto_on == true
    end

    test "a stale read of the settings does not undo the admin save" do
      stale = Settings.get()
      assert {:ok, _} = Settings.save(%{remote_mode: :off})
      refute stale.remote_mode == :off
      assert {:ok, _} = Settings.set_remote_auto_on(true)
      assert %{remote_mode: :off, remote_auto_on: true} = Settings.get()
    end

    test "with no stored row it stores the defaults plus the flag" do
      assert {:ok, _} = Settings.set_remote_auto_on(true)

      assert %{remote_mode: :auto, remote_backlog_threshold: 10, remote_auto_on: true} =
               Settings.get()
    end
  end
end
