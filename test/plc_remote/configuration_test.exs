defmodule PlcRemote.ConfigurationTest do
  use ExUnit.Case, async: true

  alias PlcRemote.{Configuration, Settings}
  alias PlcRemote.Settings.Store

  test "restores the pre-service snapshot after an interrupted or power-lost transaction" do
    directory =
      Path.join(System.tmp_dir!(), "plc-remote-config-#{System.unique_integer([:positive])}")

    path = Path.join(directory, "settings.json")
    rollback_path = path <> ".service-rollback"
    on_exit(fn -> File.rm_rf(directory) end)

    original = Settings.defaults(service_psk: "commissioning-key")
    candidate = put_in(original.uplink.regulatory_domain, "US")

    assert :ok = Store.save(path, candidate)
    assert :ok = Store.save(rollback_path, original)
    assert {:ok, state} = Configuration.init(path: path)
    assert state.settings == original
    refute File.exists?(rollback_path)
    assert {:ok, ^original, :existing} = Store.load(path, service_psk: "unused")
  end
end
