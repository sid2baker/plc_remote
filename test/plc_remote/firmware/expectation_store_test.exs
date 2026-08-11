defmodule PlcRemote.Firmware.ExpectationStoreTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias PlcRemote.Firmware.ExpectationStore

  test "persists and clears pre-update remote-connectivity evidence" do
    directory =
      Path.join(System.tmp_dir!(), "plc-remote-update-#{System.unique_integer([:positive])}")

    path = Path.join(directory, "expectation.json")
    on_exit(fn -> File.rm_rf(directory) end)

    refute ExpectationStore.load(path)
    assert :ok = ExpectationStore.mark(path)
    assert ExpectationStore.load(path)
    assert {:ok, stat} = File.stat(path)
    assert (stat.mode &&& 0o777) == 0o600
    assert :ok = ExpectationStore.clear(path)
    refute ExpectationStore.load(path)
  end
end
