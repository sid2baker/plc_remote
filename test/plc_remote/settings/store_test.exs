defmodule PlcRemote.Settings.StoreTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias PlcRemote.Settings
  alias PlcRemote.Settings.Store

  test "persists settings atomically with owner-only permissions" do
    directory =
      Path.join(System.tmp_dir!(), "plc-remote-store-#{System.unique_integer([:positive])}")

    path = Path.join(directory, "settings.json")
    settings = Settings.defaults(service_psk: "commissioning-key")

    on_exit(fn -> File.rm_rf(directory) end)

    assert :ok = Store.save(path, settings)
    assert {:ok, loaded, :existing} = Store.load(path, service_psk: "unused-fallback")
    assert loaded == settings
    assert {:ok, stat} = File.stat(path)
    assert (stat.mode &&& 0o777) == 0o600
    assert {:ok, directory_stat} = File.stat(directory)
    assert (directory_stat.mode &&& 0o777) == 0o700
    refute File.exists?(path <> ".tmp")
  end
end
