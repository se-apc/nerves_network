################################################################
# Copyright (C) 2022 Schneider Electric                        #
################################################################

defmodule Nerves.Network.EAPoLManagerTest do
  use ExUnit.Case, async: false
  doctest Nerves.Network.EAPoLManager

  defp start_dependencies do
    ## terminate NetworkManager.Supervisor to stop real modules. This allows the mock modules to be started and used instead
    GenServer.start_link(__MODULE__, [], name: Nerves.NetworkInterface.Worker)
    GenServer.start_link(__MODULE__, [], name: Nerves.Network.Config)

    setup = %{
      :ssid => "eth0-eapol",
      :identity => "user@example.org",
      :ca_cert => "/var/system/pub/eapol/ca.pem",
      :client_cert => "/var/system/pub/eapol/user@example.org.pem",
      :private_key => "/var/system/priv/eapol/user@example.org.key",
      :private_key_passwd => "whatever"
    }

    Nerves.Network.EAPoLManager.start("eth0", setup)

    :ok
  end

  setup_all do
    IO.puts("Starting AssertionTest")
    start_dependencies()

    # Context is not updated here
    :ok
  end

  test "the truth" do
    assert 1 + 1 == 2
  end
end
