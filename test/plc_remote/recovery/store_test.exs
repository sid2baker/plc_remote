defmodule PlcRemote.Recovery.StoreTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias PlcRemote.Recovery.Store

  test "persists the reboot budget with owner-only permissions" do
    directory =
      Path.join(System.tmp_dir!(), "plc-remote-recovery-#{System.unique_integer([:positive])}")

    path = Path.join(directory, "recovery.json")
    on_exit(fn -> File.rm_rf(directory) end)

    assert :ok = Store.save(path, %{consecutive_reboots: 2})
    assert Store.load(path) == %{consecutive_reboots: 2}
    assert {:ok, stat} = File.stat(path)
    assert (stat.mode &&& 0o777) == 0o600
  end

  test "corrupt or missing state safely restores an empty budget" do
    path = Path.join(System.tmp_dir!(), "missing-recovery-#{System.unique_integer([:positive])}")
    assert Store.load(path) == %{consecutive_reboots: 0}
    assert :ok = File.write(path, "not json")
    assert Store.load(path) == %{consecutive_reboots: 0}
    File.rm(path)
  end
end
