Code.require_file("qemu.exs", __DIR__)

case System.argv() do
  ["console", socket, log | commands] when commands != [] ->
    PlcRemote.Test.QEMU.console(socket, log, commands)

  ["link", socket, device, state] when state in ["up", "down"] ->
    PlcRemote.Test.QEMU.set_link(socket, device, state == "up")

  _other ->
    IO.puts(
      :stderr,
      "usage: qemu_cli.exs console SOCKET LOG COMMAND... | link SOCKET DEVICE up|down"
    )

    System.halt(2)
end
