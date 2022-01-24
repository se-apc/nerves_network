################################################################
# Copyright (C) 2022 Schneider Electric                        #
################################################################

defmodule Nerves.Network.EAPoLManagerTest do
  use ExUnit.Case, async: false
  doctest Nerves.Network.EAPoLManager

  defp start_dependencies do
    #GenServer.start_link(__MODULE__, [], name: Nerves.NetworkInterface.Worker)
    #GenServer.start_link(__MODULE__, [], name: Nerves.Network.Config)

    Nerves.Network.teardown("eth0", [eapol: true])
    Nerves.Network.setup("eth0", [eapol: true])
    :timer.sleep 1111

    #Nerves.Network.EAPoLManager.start("eth0", setup)

    :ok
  end

  defp list_wpa_processes() do
      x = System.cmd "ps", ["-C", "wpa_supplicant"]
      IO.puts "+++ ps = #{inspect x}"
  end

  setup_all do
    start_dependencies()

    #    setup = %{
    #      :ssid => "eth0-eapol",
    #      :identity => "user@example.org",
    #      :ca_cert => "/var/system/pub/eapol/ca.pem",
    #      :client_cert => "/var/system/pub/eapol/user@example.org.pem",
    #      :private_key => "/var/system/priv/eapol/user@example.org.key",
    #      :private_key_passwd => "whatever"
    #    }

    #    Nerves.Network.EAPoLManager.start("eth0", setup)

    on_exit(fn ->
      Nerves.Network.EAPoLManager.stop("eth0")
      #:timer.sleep 2500
      list_wpa_processes()
      :ok
    end)

    # Context is not updated here
    :ok
  end

  setup do
    setup = %{
      :ssid => "eth0-eapol",
      :identity => "user@example.org",
      :ca_cert => "/var/system/pub/eapol/ca.pem",
      :client_cert => "/var/system/pub/eapol/user@example.org.pem",
      :private_key => "/var/system/priv/eapol/user@example.org.key",
      :private_key_passwd => "whatever"
    }

    Nerves.Network.EAPoLManager.start("eth0", setup)

    on_exit(fn ->
      Nerves.Network.EAPoLManager.stop("eth0")
      #:timer.sleep 2500
      list_wpa_processes()
      :ok
    end)

    :ok
  end

  test "start_1" do
    setup = %{
       :ssid => "eth0-eapol",
       :identity => "user@example.org",
       :ca_cert => "/var/system/pub/eapol/ca.pem",
       :client_cert => "/var/system/pub/eapol/user@example.org.pem",
       :private_key => "/var/system/priv/eapol/user@example.org.key",
       :private_key_passwd => "whatever"
     }
    retval = Nerves.Network.EAPoLManager.start("eth0", setup)
    assert is_map(retval)

  end

  test "start_2" do
    setup = %{
       :ssid => "eth0-eapol",
       :identity => "user@example.org",
       :ca_cert => "/var/system/pub/eapol/ca.pem",
       :client_cert => "/var/system/pub/eapol/user@example.org.pem",
       :private_key => "/var/system/priv/eapol/user@example.org.key",
       :private_key_passwd => "whatever"
     }
    :ok = Nerves.Network.EAPoLManager.setup("eth0", setup)
    retval = Nerves.Network.EAPoLManager.start("eth0")
    %{wpa_pid: wpa_pid, supplicant_port: supplicant_port} = retval
    assert is_pid(wpa_pid)
    assert is_port(supplicant_port)
    assert is_map(retval)
  end

  test "state" do
    retval = Nerves.Network.EAPoLManager.state("eth0")
    assert is_map(retval)
  end

  test "setup" do
    cfg = %{
       :ssid => "eth0-eapol",
       :identity => "user2@example.org",
       :ca_cert => "/var/system/pub/eapol/ca.pem",
       :client_cert => "/var/system/pub/eapol/user2@example.org.pem",
       :private_key => "/var/system/priv/eapol/user2@example.org.key",
       :private_key_passwd => "whatever2"
     }
    assert :ok == Nerves.Network.EAPoLManager.setup("eth0", cfg)
  end

  test "reconfigure" do
    setup = %{
      :ssid => "nmc-eapol",
      :identity => "user@example.org",
      :ca_cert => "/var/system/pub/eapol/ca.pem",
      :client_cert => "/var/system/priv/eapol/user@example.org.pem",
      :private_key => "/var/system/priv/eapol/user@example.org.pem",
      :private_key_passwd => "whatever"
    }
     Elixir.Nerves.Network.EAPoLManager.start("eth0", setup)
     cfg = %{
        :ssid => "eth0-eapol",
        :identity => "user2@example.org",
        :ca_cert => "/var/system/pub/eapol/ca.pem",
        :client_cert => "/var/system/pub/eapol/user2@example.org.pem",
        :private_key => "/var/system/priv/eapol/user2@example.org.key",
        :private_key_passwd => "whatever2"
      }
    assert :ok == Nerves.Network.EAPoLManager.setup("eth0", cfg)
    assert :ok == Nerves.Network.EAPoLManager.reconfigure("eth0")
  end

  test "stop" do
    retval = Nerves.Network.EAPoLManager.stop("eth0")
    assert is_map(retval)
  end

  test "the truth" do
    assert 1 + 1 == 2
  end


end
