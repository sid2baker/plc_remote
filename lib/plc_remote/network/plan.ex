defmodule PlcRemote.Network.Plan do
  @moduledoc """
  Pure fail-closed Ethernet plan.

  Every plan contains the complete disable baseline even when role resolution
  fails. `Network.Actions.apply/1` therefore always disables every detected
  Ethernet interface before returning a planning error or enabling valid roles.
  """

  alias PlcRemote.Network

  @enforce_keys [:disable, :enable, :roles, :error]
  defstruct @enforce_keys

  @type configuration :: {Network.ifname(), map()}
  @type t :: %__MODULE__{
          disable: [configuration()],
          enable: [configuration()],
          roles: %{Network.role() => Network.ifname() | nil},
          error: term() | nil
        }

  @spec build(PlcRemote.Settings.t(), [Network.interface_info()]) :: t()
  def build(settings, interfaces) do
    {enable, error} =
      case Network.ethernet_configurations(settings, interfaces) do
        {:ok, configurations} -> {configurations, nil}
        {:error, reason} -> {[], reason}
      end

    %__MODULE__{
      disable: Network.ethernet_baseline(interfaces),
      enable: enable,
      roles: Network.role_ifnames(settings, interfaces),
      error: error
    }
  end
end
