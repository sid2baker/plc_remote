defmodule PlcRemote.ConfigurationTest do
  use ExUnit.Case, async: true

  alias PlcRemote.{Configuration, Settings}
  alias PlcRemote.Settings.Store

  test "loads the last atomically persisted settings directly" do
    directory =
      Path.join(System.tmp_dir!(), "plc-remote-config-#{System.unique_integer([:positive])}")

    path = Path.join(directory, "settings.json")
    on_exit(fn -> File.rm_rf(directory) end)

    settings =
      Settings.defaults(service_psk: "service-access-key")
      |> put_in([Access.key(:uplink), Access.key(:regulatory_domain)], "US")

    assert :ok = Store.save(path, settings)
    assert {:ok, state} = Configuration.init(path: path)
    assert state.settings == settings
    assert {:ok, ^settings, :existing} = Store.load(path, service_psk: "unused")
  end
end
