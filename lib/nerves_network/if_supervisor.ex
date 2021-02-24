defmodule Nerves.Network.IFSupervisor do
  require Logger
  use Supervisor
  alias Nerves.Network.Types
  import Nerves.Network.Utils, only: [log_atomized_iface_error: 1]

  @moduledoc false

  @type manager :: Nerves.Network.StaticManager | Nerves.Network.LinkLocalManager | Nerves.Network.DHCPManager | Nerves.Network.WiFiManager

  @spec start_link(GenServer.options) :: GenServer.on_start()
  def start_link(options \\ []) do
    {:ok, sup_pid} = Supervisor.start_link(__MODULE__, [], options)
    Logger.debug fn -> "#{__MODULE__}: sup_pid = #{inspect sup_pid}" end
    {:ok, sup_pid}
  end

  def init([]) do
    {:ok, {{:one_for_one, 10, 3600}, []}}
  end

  defp restart_type(_manager = Nerves.Network.DHCPv6Manager) do
    :transient
  end

  defp restart_type(_manager) do
    :permanent
  end

  @spec setup(Types.ifname | atom, Nerves.Network.setup_settings) :: [Supervisor.on_start_child()]
  def setup(ifname, settings) when is_atom(ifname) do
    log_atomized_iface_error(ifname)
    setup(to_string(ifname), settings)
  end

  def setup(ifname, settings) do
    Logger.debug"#{ifname} (#{inspect settings})"

    manager_modules = managers(if_type(ifname), settings)
    Logger.debug(".setup manager_modules: #{inspect manager_modules}")

    children =
      for manager <- manager_modules  do
        child_name = pname(ifname, manager)
        worker(manager, [ifname, settings, [name: child_name]], [id: {pname(ifname), child_name}, restart: restart_type(manager)])
      end

    Logger.debug(".setup children: #{inspect children}")

    result =
      {:ok, for child <- children do
              Logger.debug(".setup Starting child: #{inspect child}...")
              retval = Supervisor.start_child(__MODULE__, child)
              Logger.debug(".setup retval = #{inspect retval}...")
              retval
            end #For child <- children
      }

    Logger.debug(".setup returns #{inspect result}")

    result
  end



  @doc """
  Returns `{:ok, list()}`.

  ## Parameters
  - ifname: String identifying network interface's name i.e. "eth0"
  - settings: a Keyword list with the settings i.e. [ipv4_address_method: :dhcp, ipv6_dhcp: stateless]. For stop function the key values are
            irelevant because the settings are used for only locating an appropriate manager tied to the network interface specified with ifname.

  ## Examples

        iex> Nerves.Network.IFSupervisor.stop("eth0", [ipv6_dhcp: :stateless])
        {:ok, [ok: :ok]}

        iex> Nerves.Network.IFSupervisor.stop("eth0", [ipv4_address_method: :dhcp])
        {:ok, [ok: :ok]}

        iex> Nerves.Network.IFSupervisor.stop("non_existent", [ipv6_dhcp: :stateless])
        [{{:error, :not_found}, {:error, :not_found}}]

  """
  @spec stop(Types.ifname, list()) :: {:ok, list(child_termination_t())}
  def stop(ifname, settings) do
    Logger.debug(".stop ifname = #{inspect ifname}; settings = #{inspect settings}")
    manager_modules = managers(if_type(ifname), settings)

    children =
      for manager <- manager_modules  do
        #For termination we only need parent and child names
        child_name  = pname(ifname, manager)
        parent_name = pname(ifname)
        {parent_name, child_name}
      end

    Logger.debug(".stop children: #{inspect children}")

    result = {:ok, for child <- children do
                      Logger.debug(".stop Stopping child: #{inspect child}...")
                      retval = terminate_child(child)
                      Logger.debug(".stop retval = #{inspect retval}...")
                      retval
                    end #For child <- children
      }

    Logger.debug(".stop result: #{inspect result}")
    result
  end

  @type deletion_supervisor_error :: :not_found | :simple_one_for_one | :running | :restarting
  @type termination_supervisor_error :: :not_found | :simple_one_for_one
  @type termination_retval_t ::  :ok | {:error, termination_supervisor_error()}
  @type deletion_retval_t ::  :ok | {:error, deletion_supervisor_error()}
  @type child_termination_t :: {termination_retval_t(), deletion_retval_t()}

  #Child is one of the following sample specs:
  #  spec1: {{:"Nerves.Network.Interface.ens33", :"Elixir.Nerves.Network.DHCPv6Manager.ens33"}, #PID<0.216.0>, :worker, [Nerves.Network.DHCPv6Manager]}
  #  spec2: {{:"Nerves.Network.Interface.eth1", :"Elixir.Nerves.Network.DHCPv6Manager.eth1"},
  #          {Nerves.Network.DHCPv6Manager, :start_link, ["eth1", [ipv6_dhcp: :stateful], [name: :"Elixir.Nerves.Network.DHCPv6Manager.eth1"]]},
  #          :transient, 5000, :worker, [Nerves.Network.DHCPv6Manager]}..
  @spec terminate_child(Supervisor.child()) :: child_termination_t()
  defp terminate_child(child) do
    {parent_name, child_name} =
      case child do
        {{parent_name, child_name}, _pid, :worker, _} -> {parent_name, child_name}
        {parent_name, child_name} -> {parent_name, child_name}
      end
    result1 = Supervisor.terminate_child(__MODULE__, {parent_name, child_name})
    result2 = Supervisor.delete_child(__MODULE__, {parent_name, child_name})
    {result1, result2}
  end

  defp belongs_to_if(child, ifname) do
    {{parent_name, _child_name}, _pid, :worker, _list} = child
    parent_name == pname(ifname)
  end

  defp if_children(children, ifname) do
    #Logger.debug fn -> "#{__MODULE__}: if_children(children=#{inspect children}, ifname=#{inspect ifname})" end
    Enum.filter(children, fn(child) -> belongs_to_if(child, ifname) end)
  end

  @spec teardown(Types.ifname) :: :ok | {:error, :not_started}
  def teardown(ifname) do
    Logger.debug fn -> "#{__MODULE__}: teardown(ifname = #{inspect ifname})" end
      #foreach Supervisor.wich_children
      sup_pid =
        __MODULE__
        |> Process.whereis()
      Logger.debug fn -> "#{__MODULE__} sup_pid: #{inspect sup_pid}" end
      if sup_pid do
        children = Supervisor.which_children(sup_pid)
                    |> if_children(ifname)
        Logger.debug fn -> "#{__MODULE__} which_children: #{inspect children}" end
        Enum.each children, fn child -> terminate_child(child) end
        Logger.debug fn -> "#{__MODULE__} which_children: #{inspect children}" end
      else
        {:error, :not_started}
      end
  end

  # Support atom interface names to avoid breaking some existing
  # code. This is a deprecated use of the API.
  @spec scan(Types.ifname | atom) :: [String.t] | {:error, any}
  def scan(ifname) when is_atom(ifname) do
    log_atomized_iface_error(ifname)
    scan(to_string(ifname))
  end
  def scan(ifname) when is_binary(ifname) do
    with pid when is_pid(pid) <- Process.whereis(pname(ifname)),
      :wireless <- if_type(ifname) do
        GenServer.call(pid, :scan, 30_000)
      else
       # If there is no pid.
       nil -> {:error, :not_started}
       # if the interface was wired.
       :wired -> {:error, :not_wireless}
      end
  end

  @spec pname(Types.ifname) :: atom
  defp pname(ifname) when is_atom(ifname) do
    ifname
    |> to_string()
    |> pname()
  end

  defp pname(ifname) when is_binary(ifname) do
    String.to_atom("Nerves.Network.Interface." <> ifname)
  end

  @spec pname(Types.ifname, manager()) :: atom
  defp pname(ifname, manager) do
    String.to_atom(to_string(manager) <> "." <> ifname)
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

  @spec managers(:wired | :wireless, Nerves.Network.setup_settings) :: [manager()]
  defp managers(:wired, settings) do
    Logger.debug fn -> "#{__MODULE__}: if_supervisor.ex .managers(:wired, settings = #{inspect settings})" end

    managers_v4 = ipv4_managers(settings)
    managers_v6 = ipv6_managers(settings)

    managers_v4 ++ managers_v6
  end

  #There currently is only one manager for WiFi
  defp managers(:wireless, _settings) do
    [Nerves.Network.WiFiManager]
  end


  @spec if_type(Types.ifname) :: :wired | :wireless
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
