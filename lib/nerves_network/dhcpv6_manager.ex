defmodule Nerves.Network.DHCPv6Manager do
  use GenServer
  require Logger
  import Nerves.Network.Utils
  alias Nerves.Network.Utils

  @moduledoc false

  # The current state machine state is called "context" to avoid confusion between server
  # state and state machine state.
  defstruct context: :removed,
            ifname: nil,
            settings: nil,
            dhcp_pid: nil,
            dhcp_retry_interval: 60_000,
            dhcp_retry_timer: nil

  def start_link(ifname, settings, opts \\ []) do
    Logger.debug(
      "DHCPv6Manager starting.... ifname: #{inspect(ifname)}; settings: #{inspect(settings)}"
    )

    GenServer.start_link(__MODULE__, {ifname, settings}, opts)
  end

  # defmodule EventHandler do
  #   use GenServer
  #
  #   @moduledoc false
  #
  #   def start_link(opts) do
  #     GenServer.start_link(__MODULE__, opts)
  #   end
  #
  #   def init({manager, ifname}) do
  #     {:ok, %{manager: manager, ifname: ifname}}
  #   end
  #
  #
  # end

  def init(arg = {ifname, settings}) do
    # Register for nerves_network_interface and dhclient events
    Logger.debug("arg = #{inspect(arg)}")

    # When the ifname network interface had already been registered with registries Nerves.NEtworkInterface or
    # Nerves.Dhclient that would not be a problem hence we can merely ignore the :already_registered :error
    # results.
    rreg_res1 =
      Registry.register(Nerves.NetworkInterface, ifname, [])
      |> Utils.Registry.digest_register_results()

    rreg_res2 =
      Registry.register(Nerves.Dhclient, ifname, []) |> Utils.Registry.digest_register_results()

    Logger.debug("rreg_res1 = #{inspect(rreg_res1)}")
    Logger.debug("rreg_res2 = #{inspect(rreg_res2)}")

    state = %Nerves.Network.DHCPv6Manager{settings: settings, ifname: ifname}

    Logger.debug("state = #{inspect(state)}")

    Logger.debug("DHCPv6Manager initialising.... state: #{inspect(state)}")
    Logger.debug("settings: #{inspect(settings)}")
    # If the interface currently exists send ourselves a message that it
    # was added to get things going.
    current_interfaces = Nerves.NetworkInterface.interfaces()

    state =
      if Enum.member?(current_interfaces, ifname) do
        consume(state.context, :ifadded, state)
      else
        state
      end

    Logger.debug("DHCPv6Manager initialising... state: #{inspect(state)}")
    {:ok, state}
  end

  def handle_event({Nerves.NetworkInterface, :ifadded, %{ifname: ifname}}) do
    Logger.debug("DHCPv6Manager.EventHandler(#{ifname}) ifadded")
    :ifadded
  end

  # :ifmoved occurs on systems that assign stable names to removable
  # interfaces. I.e. the interface is added under the dynamically chosen
  # name and then quickly renamed to something that is stable across boots.
  def handle_event({Nerves.NetworkInterface, :ifmoved, %{ifname: ifname}}) do
    Logger.debug("DHCPv6Manager.EventHandler(#{ifname}) ifadded (moved)")
    :ifadded
  end

  def handle_event({Nerves.NetworkInterface, :ifremoved, %{ifname: ifname}}) do
    Logger.debug("DHCPv6Manager.EventHandler(#{ifname}) ifremoved")
    :ifremoved
  end

  # Filter out ifup and ifdown events
  # :is_up reports whether the interface is enabled or disabled (like by the wifi kill switch)
  # :is_lower_up reports whether the interface as associated with an AP
  def handle_event({Nerves.NetworkInterface, :ifchanged, %{ifname: ifname, is_lower_up: true}}) do
    Logger.debug("DHCPv6Manager.EventHandler(#{ifname}) ifup")
    :ifup
  end

  def handle_event({Nerves.NetworkInterface, :ifchanged, %{ifname: ifname, is_lower_up: false}}) do
    Logger.debug("DHCPv6Manager.EventHandler(#{ifname}) ifdown")
    :ifdown
  end

  # # DHCP events
  # # :bound, :renew, :rebind, :nak

  def handle_event({Nerves.NetworkInterface, event, %{ifname: ifname}}) do
    Logger.debug("DHCPv6Manager.EventHandler(#{ifname}): ignoring event: #{inspect(event)}")
    :noop
  end

  def handle_info({source = Nerves.NetworkInterface, _, ifstate} = event, %{ifname: ifname} = s) do
    Logger.debug("source = #{inspect source}; ifstate = #{inspect(ifstate)}")
    event = handle_event(event)
    scope(ifname) |> SystemRegistry.update(ifstate)
    s = consume(s.context, event, s)
    Logger.debug("(#{s.ifname}, #{s.context}) got event #{inspect(event)}")
    {:noreply, s}
  end

  #  info: %{domain_search: "ipv6.doman.name", ifname: "eth1", ipv6_address: "666::16/64", nameservers: ["fec0:0:0:1::7"]}
  def handle_info({Nerves.Dhclient, event, info}, %{ifname: ifname} = s) do
    Logger.debug("(#{s.ifname}) event: #{inspect(event)}; info: #{inspect(info)}")

    scope(ifname) |> SystemRegistry.update(info)
    s = consume(s.context, {event, info}, s)
    {:noreply, s}
  end

  def handle_info(event, s) do
    Logger.debug("DHCPv6Manager.EventHandler(#{s.ifname}): ignoring event: #{inspect(event)}")
    {:noreply, s}
  end

  ## State machine implementation
  defp goto_context(state, newcontext) do
    %Nerves.Network.DHCPv6Manager{state | context: newcontext}
  end

  defp consume(_, :noop, state), do: state
  ## Context: :removed
  defp consume(:removed, :ifadded, state) do
    case Nerves.NetworkInterface.ifup(state.ifname) do
      :ok ->
        {:ok, status} = Nerves.NetworkInterface.status(state.ifname)
        notify(Nerves.NetworkInterface, state.ifname, :ifchanged, status)

        state
        |> goto_context(:down)

      {:error, _} ->
        # The interface isn't quite up yet. Retry
        Process.send_after(self(), :retry_ifadded, 250)

        state
        |> goto_context(:retry_add)
    end
  end

  defp consume(:removed, :retry_ifadded, state), do: state
  defp consume(:removed, :ifdown, state), do: state

  ## Context: :retry_add
  defp consume(:retry_add, :ifremoved, state) do
    state
    |> goto_context(:removed)
  end

  defp consume(:retry_add, :retry_ifadded, state) do
    {:ok, status} = Nerves.NetworkInterface.status(state.ifname)
    notify(Nerves.NetworkInterface, state.ifname, :ifchanged, status)

    state
    |> goto_context(:down)
  end

  ## Context: :down
  defp consume(:down, :ifadded, state), do: state

  defp consume(:down, :ifup, state) do
    state
    |> start_dhclient
    |> goto_context(:dhcpv6)
  end

  defp consume(:down, :ifdown, state) do
    state
    |> stop_dhclient
  end

  defp consume(:down, :ifremoved, state) do
    state
    |> stop_dhclient
    |> goto_context(:removed)
  end

  ## Context: :dhcpv6
  defp consume(:dhcpv6, :ifup, state), do: state
  defp consume(:dhcpv6, {:deconfig, _info}, state), do: state

  defp consume(:dhcpv6, {:bound, info}, state) do
    Logger.debug(":dhcp6 :bound info: #{inspect(info)}")

    state
    |> configure(info)
    |> goto_context(:dhcpv6)
  end

  defp consume(:dhcpv6, {:renew, info}, state) do
    Logger.debug(":dhcp6 :renew info: #{inspect(info)}")

    state
    |> configure(info)
    |> goto_context(:dhcpv6)
  end

  defp consume(:dhcpv6, {:leasefail, _info}, state) do
    dhcp_retry_timer = Process.send_after(self(), :dhcp_retry, state.dhcp_retry_interval)

    %{state | dhcp_retry_timer: dhcp_retry_timer}
    |> stop_dhclient
    |> start_link_local
    |> goto_context(:up)
  end

  defp consume(:dhcpv6, {:expire, info}, state) do
    Logger.debug(":dhcpv6 :expire info: #{inspect(info)}")

    :no_resolv_conf
    |> configure(state, info)
    |> goto_context(:up)
  end

  defp consume(:dhcpv6, :ifdown, state) do
    state
    |> stop_dhclient
    |> goto_context(:down)
  end

  ## Context: :up
  defp consume(:up, :ifup, state), do: state

  defp consume(:up, :dhcp_retry, state) do
    state
    |> start_dhclient
    |> goto_context(:dhcpv6)
  end

  defp consume(:up, :ifdown, state) do
    state
    |> stop_dhclient
    |> deconfigure
    |> goto_context(:down)
  end

  defp consume(:up, {:leasefail, _info}, state), do: state

  defp consume(:up, {:bound, info}, state) do
    Logger.debug(":up :bound info: #{inspect(info)}")

    configure(state, info)
    |> goto_context(:dhcpv6)
  end

  defp consume(:up, {:renew, info}, state) do
    Logger.debug(":up :renew info: #{inspect(info)}")

    configure(state, info)
    |> goto_context(:dhcpv6)
  end

  defp consume(:up, {:rebind, info}, state) do
    Logger.debug(
      ":up :rebind info: #{inspect(info)}"
      |> configure(state, info)
      |> goto_context(:dhcpv6)
    )
  end

  defp consume(:up, {:release, info}, state) do
    Logger.debug(":up :release info: #{inspect(info)}")

    :no_resolv_conf
    |> configure(state, info)
    |> goto_context(:up)
  end

  defp consume(:up, {:expire, info}, state) do
    Logger.debug(":up :expire info: #{inspect(info)}")

    :no_resolv_conf
    |> configure(state, info)
    |> goto_context(:up)
  end

  defp consume(:up, {:stop, info}, state) do
    Logger.debug(":stop info: #{inspect(info)}")

    :no_resolv_conf
    |> configure(state, info)
    |> goto_context(:up)
  end

  # Catch-all handler for consume
  defp consume(context, event, state) do
    Logger.warn("Unhandled event #{inspect(event)} for context #{inspect(context)} in consume/3.")
    state
  end

  defp stop_dhclient(state) do
    if is_pid(state.dhcp_pid) do
      Nerves.Network.Dhclient.stop(state.dhcp_pid)
      %Nerves.Network.DHCPv6Manager{state | dhcp_pid: nil}
    else
      state
    end
  end

  defp start_dhclient(state) do
    state = stop_dhclient(state)
    # state = start_link_local(state)
    {:ok, pid} = Nerves.Network.Dhclient.start_link({state.ifname, state.settings[:ipv6_dhcp]})
    %Nerves.Network.DHCPv6Manager{state | dhcp_pid: pid}
  end

  defp start_link_local(state) do
    {:ok, ifsettings} = Nerves.NetworkInterface.status(state.ifname)
    ip = generate_link_local(ifsettings.mac_address)

    scope(state.ifname)
    |> SystemRegistry.update(%{ipv6_address: ip})

    :ok = Nerves.NetworkInterface.setup(state.ifname, ipv6_address: ip)
    state
  end

  # When the new IPv6 address is being specified we do not need to do anything.
  defp translate_ipv6_address(info = %{ipv6_address: _ipv6_address, old_ipv6_address: _old_ipv6_address}) do
    info
  end

  # When the new IPv6 address hasn't been specified but the old IPv6 address has been, we shall provide an empty string for new IPv6.
  # This is common scenarion in the case of DHCPv6 IP address expiration or lack of bind to the IPv6 network with the corresponding DHCPv6
  # server, from which, we have a valid lease.
  defp translate_ipv6_address(info = %{old_ipv6_address: _old_ipv6_address}) do
    Map.put(info, :ipv6_address, "")
  end

  #We shall simply forward all other cases
  defp translate_ipv6_address(info) do
    info
  end

  # Nerves.NetworkInterface will report {:error, :einval} when an empty string is passed as IPv6 address.
  defp drop_ipv6_address_if_empty(info = %{ipv6_address: ""}) do
    Map.drop(info, [:ipv6_address])
  end

  defp drop_ipv6_address_if_empty(info) do
    info
  end

  defp setup_iface(state, info) do
    case Nerves.NetworkInterface.setup(state.ifname, drop_ipv6_address_if_empty(info)) do
      :ok ->
        Logger.info("notifying Nerves.NetworkInterface :ifchanged - info #{inspect(info)}")
        notify(Nerves.NetworkInterface, state.ifname, :ifchanged, translate_ipv6_address(info))
        :ok

      {:error, :eexist} ->
        :ok

      other ->
        Logger.warn("Unexpected return from Nerves.NetworkInterface.setup(#{inspect state.ifname}, #{inspect info}")
        :ok

        # It may very often happen that at the renew time we would receive the lease of the very same IP address...
        # In such a case whilst adding already existent IP address to the network interface we shall receive 'error exists'.
        # It definitely is non-critical situation and actually confirms that we do not have to take any action.
    end
  end

  defp remove_old_ip(state, info) do
    old_ip = info[:old_ipv6_address] || ""
    new_ip = info[:ipv6_address] || ""

    if old_ip == "" or new_ip == old_ip do
      :ok
    else
      Logger.debug("Removing ipv6 address = #{inspect(old_ip)} from #{inspect(state.ifname)}")
      Nerves.NetworkInterface.setup(state.ifname, %{:"-ipv6_address" => old_ip})
    end
  end

  defp configure(:no_resolv_conf, state, info) do
    remove_old_ip(state, info)
    :ok = setup_iface(state, Map.put(info, :dhcpv6_mode, Keyword.get(state.settings, :ipv6_dhcp)))
    state
  end

  defp configure(state, info) do
    Logger.warn("DHCP state #{inspect(state)} #{inspect(info)}")

    # We want to fetch the key :ipv6_dhcp = [:stateful | :stateless] from the state.settings list of key-value pairs
    # and implant it in the info map communicated to the registered listeners
    :ok = setup_iface(state, Map.put(info, :dhcpv6_mode, Keyword.get(state.settings, :ipv6_dhcp)))
    :ok = Nerves.Network.Resolvconf.setup(Nerves.Network.Resolvconf, state.ifname, info)

    # Show that the route has been updated
    System.cmd("route", []) |> elem(0) |> Logger.error()
    state
  end

  defp deconfigure(state) do
    :ok = Nerves.Network.Resolvconf.clear(Nerves.Network.Resolvconf, state.ifname)
    state
  end
end
