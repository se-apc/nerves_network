defmodule Nerves.Network.IFSupervisor do
  require Logger
  use Supervisor

  @moduledoc false

  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, [], options)
  end

  def init([]) do
      {:ok, {{:one_for_one, 10, 3600}, []}}
  end

  def setup(ifname, settings) when is_atom(ifname) do
    setup(to_string(ifname), settings)
  end
  def setup(ifname, settings) do
    Logger.debug fn -> "#{__MODULE__} setup(#{ifname}, #{inspect settings})" end
    pidname = pname(ifname)
    Logger.debug fn -> "#{__MODULE__} pidname: #{inspect pidname}" end
    if !Process.whereis(pidname) do
      manager_modules = managers(if_type(ifname), settings)
      Logger.debug fn -> "#{__MODULE__} manager_modules: #{inspect manager_modules}" end
      children = for manager <- manager_modules  do
            child_name = pname(ifname, manager)
            worker(manager,
                                                      [ifname, settings, [name: child_name]],
                                                      #                                                      id: {pidname, manager})
                                                      id: child_name)
        end
      Logger.debug fn -> "#{__MODULE__} children: #{inspect children}" end

      #result = supervise(children, [strategy: :one_for_one])
      result = {:ok, for child <- children do
                        Logger.debug  fn -> "Starting child: #{inspect child}..." end
                        retval = Supervisor.start_child(__MODULE__, child)
                        Logger.debug  fn -> "   retval = #{inspect retval}..." end
                        retval
                     end #For child <- children 
        }

      #which_children = Supervisor.which_children(pidname);
      #Logger.debug fn -> "#{__MODULE__} which_children: #{inspect which_children}" end
      Logger.debug fn -> "#{__MODULE__} setup result: #{inspect result}" end

      result
    else
      Logger.debug ":error, :already_added"
      {:error, :already_added}
    end
  end

  def teardown(ifname) do
    pidname = pname(ifname)
    if Process.whereis(pidname) do
      #foreach Supervisor.wich_children
      Supervisor.terminate_child(__MODULE__, pidname)
      Supervisor.delete_child(__MODULE__, pidname)
    else
      {:error, :not_started}
    end
  end

  def scan(ifname) do
     pidname = pname(ifname)
     if Process.whereis(pidname) do
       GenServer.call(pidname, :scan, 30_000)
     else
       {:error, :not_started}
     end
  end

  defp pname(ifname) do
    String.to_atom("Nerves.Network.Interface." <> ifname)
  end

  defp pname(ifname, manager) do
    String.to_atom("Nerves.Network.Interface." <> ifname <> to_string(manager))
  end

  defp ipv4_managers(settings) do
    case Keyword.get(settings, :ipv4_address_method) do
      :static -> [Nerves.Network.StaticManager]
      :linklocal -> [Nerves.Network.LinkLocalManager]
      :dhcp -> [Nerves.Network.DHCPManager]

      # We may want no IPv4 manager to be selected
      nil -> []
    end
  end

  defp ipv6_managers(settings) do
      static_managers = if settings[:ipv6_static] do
                          [] #Should contain Nerves.Network.Ipv6StaticManager
                        else
                          []
                        end

      auto_managers = if settings[:ipv6_autoconf] do
                          [] #Should contain Nerves.Network.Ipv6AutoconfManager
                      else
                          []
                      end

      dhcp_managers = case settings[:ipv6_dhcp] do
                          :stateful-> [Nerves.Network.DHCPv6Manager]
                          :stateless -> [Nerves.Network.DHCPv6Manager]
                          :never -> []
                          nil -> []
                      end

      static_managers ++ auto_managers ++ dhcp_managers
  end

  # Return the appropriate interface managers based on the interface's type
  # and settings. Typically there should be zero or one only manager for IPv4, whereas there may be
  # multiple managers for IPv6 (i.e. static, autoconf, DHCPv6)
  defp managers(:wired, settings) do
    Logger.debug fn -> "if_supervisor.ex .managers(:wired, settings = #{inspect settings})" end

    managers_v4 = ipv4_managers(settings)
    managers_v6 = ipv6_managers(settings)

    managers_v4 ++ managers_v6
  end

  #There currently is only one manager for WiFi
  defp managers(:wireless, _settings) do
    [Nerves.Network.WiFiManager]
  end

  # Categorize networks into wired and wireless based on their if names
  defp if_type(<<"eth", _rest::binary>>), do: :wired
  defp if_type(<<"usb", _rest::binary>>), do: :wired
  defp if_type(<<"lo", _rest::binary>>), do: :wired  # Localhost
  defp if_type(<<"wlan", _rest::binary>>), do: :wireless
  defp if_type(<<"ra", _rest::binary>>), do: :wireless  # Ralink

  # systemd predictable names
  defp if_type(<<"en", _rest::binary>>), do: :wired
  defp if_type(<<"sl", _rest::binary>>), do: :wired # SLIP
  defp if_type(<<"wl", _rest::binary>>), do: :wireless
  defp if_type(<<"ww", _rest::binary>>), do: :wired # wwan (not really supported)

  defp if_type(_ifname), do: :wired
end
