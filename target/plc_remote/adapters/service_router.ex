defmodule PlcRemote.Adapters.Target.ServiceRouter do
  @moduledoc false

  @behaviour PlcRemote.Adapters.ServiceRouter

  @comment "plc-remote-service"

  @impl true
  def enable(service_ifname, wan_ifname) do
    case install_rules(service_ifname, wan_ifname) do
      :ok ->
        write_forwarding("1")

      {:error, _reason} = error ->
        disable()
        error
    end
  end

  defp install_rules(service_ifname, wan_ifname) do
    with :ok <- disable(),
         :ok <-
           iptables([
             "-t",
             "nat",
             "-A",
             "POSTROUTING",
             "-o",
             wan_ifname,
             "-m",
             "comment",
             "--comment",
             @comment,
             "-j",
             "MASQUERADE"
           ]),
         :ok <-
           iptables([
             "-A",
             "FORWARD",
             "-i",
             service_ifname,
             "-o",
             wan_ifname,
             "-m",
             "comment",
             "--comment",
             @comment,
             "-j",
             "ACCEPT"
           ]),
         :ok <-
           iptables([
             "-A",
             "FORWARD",
             "-i",
             wan_ifname,
             "-o",
             service_ifname,
             "-m",
             "conntrack",
             "--ctstate",
             "RELATED,ESTABLISHED",
             "-m",
             "comment",
             "--comment",
             @comment,
             "-j",
             "ACCEPT"
           ]) do
      iptables([
        "-A",
        "FORWARD",
        "-i",
        service_ifname,
        "-m",
        "comment",
        "--comment",
        @comment,
        "-j",
        "REJECT"
      ])
    end
  end

  @impl true
  def disable do
    delete_matching_rules("filter", "FORWARD", [])
    delete_matching_rules("nat", "POSTROUTING", ["-t", "nat"])
    write_forwarding("0")
  end

  defp delete_matching_rules(table, chain, table_args) do
    case MuonTrap.cmd("iptables-save", ["-t", table], stderr_to_stdout: true) do
      {rules, 0} ->
        rules
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "-A #{chain} "))
        |> Enum.filter(&String.contains?(&1, @comment))
        |> Enum.reverse()
        |> Enum.each(fn "-A " <> rule ->
          [saved_chain | args] = OptionParser.split(rule)
          discard_iptables(table_args ++ ["-D", saved_chain | args])
        end)

      _error ->
        :ok
    end
  end

  defp discard_iptables(args) do
    _result = iptables(args)
    :ok
  end

  defp iptables(args) do
    case MuonTrap.cmd("iptables", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:iptables, status, sanitize(output)}}
    end
  rescue
    error -> {:error, {:iptables_unavailable, error.__struct__}}
  end

  defp write_forwarding(value) do
    case File.write("/proc/sys/net/ipv4/ip_forward", value) do
      :ok -> :ok
      {:error, reason} -> {:error, {:ip_forwarding, reason}}
    end
  end

  defp sanitize(output) do
    output
    |> String.trim()
    |> String.slice(0, 240)
  end
end
