defmodule Nerves.Network.DHCPManager do
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
      "DHCPManager starting.... ifname: #{inspect(ifname)}; settings: #{inspect(settings)}"
    )

    GenServer.start_link(__MODULE__, {ifname, settings}, opts)
  end

  def init({ifname, settings}) do
    # When the ifname network interface had already been registered with registries Nerves.NetworkInterface or
    # Nerves.Dhclient that would not be a problem hence we can merely ignore the :already_registered :error
    # results.
    rreg_res1 =
      Registry.register(Nerves.NetworkInterface, ifname, [])
      |> Utils.Registry.digest_register_results()

    rreg_res2 =
      Registry.register(Nerves.Dhclientv4, ifname, []) |> Utils.Registry.digest_register_results()

    Logger.debug(".init   rreg_res1 = #{inspect(rreg_res1)}")
    Logger.debug(".init   rreg_res2 = #{inspect(rreg_res2)}")

    state = %Nerves.Network.DHCPManager{settings: settings, ifname: ifname}
    Logger.debug("DHCPManager initialising.... state: #{inspect(state)}")
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

    Logger.debug("DHCPManager initialising.... state: #{inspect(state)}")
    {:ok, state}
  end

  def handle_event({Nerves.NetworkInterface, :ifadded, %{ifname: ifname}}) do
    Logger.debug("DHCPManager.EventHandler(#{ifname}) ifadded")
    :ifadded
  end

  # :ifmoved occurs on systems that assign stable names to removable
  # interfaces. I.e. the interface is added under the dynamically chosen
  # name and then quickly renamed to something that is stable across boots.
  def handle_event({Nerves.NetworkInterface, :ifmoved, %{ifname: ifname}}) do
    Logger.debug("DHCPManager.EventHandler(#{ifname}) ifadded (moved)")
    :ifadded
  end

  def handle_event({Nerves.NetworkInterface, :ifremoved, %{ifname: ifname}}) do
    Logger.debug("DHCPManager.EventHandler(#{ifname}) ifremoved")
    :ifremoved
  end

  # Filter out ifup and ifdown events
  # :is_up reports whether the interface is enabled or disabled (like by the wifi kill switch)
  # :is_lower_up reports whether the interface as associated with an AP
  def handle_event({Nerves.NetworkInterface, :ifchanged, %{ifname: ifname, is_lower_up: true}}) do
    Logger.debug("DHCPManager.EventHandler(#{ifname}) ifup")
    :ifup
  end

  def handle_event({Nerves.NetworkInterface, :ifchanged, %{ifname: ifname, is_lower_up: false}}) do
    Logger.debug("DHCPManager.EventHandler(#{ifname}) ifdown")
    :ifdown
  end

  # # DHCP events
  # # :bound, :renew, :rebind, :nak

  def handle_event({Nerves.NetworkInterface, event, %{ifname: ifname}}) do
    Logger.debug("DHCPManager.EventHandler(#{ifname}): ignoring event: #{inspect(event)}")
    :noop
  end

  def handle_info({Nerves.NetworkInterface, _, ifstate} = event, %{ifname: ifname} = s) do
    Logger.debug("handle_info: ifstate = #{inspect(ifstate)}")
    event = handle_event(event)
    scope(ifname) |> SystemRegistry.update(ifstate)

    Logger.debug("Calling consume #{inspect s.context}; event = ${inspect event} state = #{inspect s}")

    s = consume(s.context, event, s)

    Logger.debug("DHCPManager(#{s.ifname}, #{s.context}) got event #{inspect(event)}")

    {:noreply, s}
  end

  #  info: %{domain_search: "ipv4.doman.name", ifname: "eth1", ipv4_address: "666::16/64", nameservers: ["fec0:0:0:1::7"]}
  def handle_info({Nerves.Dhclientv4, event, info}, %{ifname: ifname} = s) do
    Logger.debug(
      "DHCPManager.EventHandler(#{s.ifname}) event: #{inspect(event)}; info: #{inspect(info)}"
    )

    scope(ifname) |> SystemRegistry.update(info)
    s = consume(s.context, {event, info}, s)
    {:noreply, s}
  end

  def handle_info(event = :dhcp_retry, s = %{ifname: ifname}) do
    Logger.debug("DHCPManager.EventHandler(#{ifname}) dhcp_retry; state = #{inspect s}")
    s = consume(s.context, event, s)
    {:noreply, s}
  end


  def handle_info(event, s) do
    Logger.debug("DHCPManager.EventHandler(#{s.ifname}): ignoring event: #{inspect(event)}")
    {:noreply, s}
  end

  ## State machine implementation
  defp goto_context(state, newcontext) do
    %Nerves.Network.DHCPManager{state | context: newcontext}
  end

  ## Context: :down

  ## covers PREINIT in Nerves.Network.Dhclientv4
  defp consume(:down, :ifup, state), do: consume(:down, {:ifup, :no_info}, state)

  defp consume(:down, {:ifup, info}, state) do
    Logger.debug("(context = :down) :ifup info: #{inspect(info)}")

    state
    |> start_dhclient
    |> goto_context(:dhcp)
  end

  ## covers BOUND, REBOOT, RENEW, REBIND in Nerves.Network.Dhclientv4.
  defp consume(:down, {event, _info}, state) when event in [:bound, :reboot, :renew, :rebind] do
    Logger.debug(":down, {event = #{inspect event}, _info}; state = #{inspect state}")

    state
  end

  ## covers STOP, RELEASE, FAIL and EXPIRE in Nerves.Network.Dhclientv4
  defp consume(:down, :ifdown, state) do
    Logger.debug(":down, :ifdown, state = #{inspect state}")

    consume(:down, {:ifdown, :no_info}, state)
  end

  defp consume(:down, {:ifdown, info}, state) do
    Logger.debug("(context = :down) :ifdown info: #{inspect(info)} state = #{inspect(state)}")

    state
    |> stop_dhclient(:ifdown)
    |> deconfigure
  end

  ## Context: :dhcp


  ## covers PREINIT in Nerves.Network.Dhclientv4
  defp consume(:dhcp, :ifup, state), do: consume(:dhcp, {:ifup, :no_info}, state)

  defp consume(:dhcp, {:ifup, info}, state) do
    Logger.debug("(context = :dhcp) :ifup info: #{inspect(info)}")

    state
  end

  ## covers BOUND, REBOOT, RENEW, REBIND in Nerves.Network.Dhclientv4
  defp consume(:dhcp, {event, info}, state)
       when event in [:bound, :reboot, :renew, :rebind, :expire] do
    Logger.debug("(context = :dhcp) #{inspect(event)} info: #{inspect(info)}")

    state
    |> configure(info)
    |> goto_context(:up)
  end

  # This event will be followed by the :leasefail, hence we want the state machine to remain in :dhcp state.
  # The subsequent :lease fail event shall move the state-machine to the :up state.
  defp consume(cur_state, {:timeout, info}, state) when cur_state in [:dhcp, :up] do
    Logger.debug("(context = :dhcp) #{inspect(:timeout)} info: #{inspect(info)}")

    # Let's try newest valid lease. It is an attempt to answer whether we are still connected to the same network as before.
    state
    |> configure(info)
    |> deconfigure_if_gateway_not_pingable(info)
  end

  ## covers STOP, RELEASE, FAIL and EXPIRE in Nerves.Network.Dhclientv4
  defp consume(:dhcp, :ifdown, state) do
    Logger.debug(":dhcp, :ifdown istate = #{inspect state}")

    consume(:dhcp, {:ifdown, :no_info}, state)
  end

  defp consume(:dhcp, {:ifdown, info}, state) do
    Logger.debug("(context = :dhcp) :ifdown info: #{inspect(info)}")

    state
    |> stop_dhclient(:ifdown)
    |> goto_context(:down)
  end

  ## Context: :up
  defp consume(:up, :ifup, state), do: consume(:up, {:ifup, :no_info}, state)

  defp consume(:up, {:ifup, info}, state) do
    Logger.debug("(context = :up) :ifup info: #{inspect(info)}")
    state
  end

  defp consume(:up, :ifdown, state), do: consume(:up, {:ifdown, :no_info}, state)

  defp consume(:up, {:ifdown, info}, state) do
    Logger.debug("(context = :up) :ifdown info: #{inspect(info)}")

    state
    |> stop_dhclient(:ifdown)
    |> deconfigure
    |> goto_context(:down)
  end

  defp consume(:up, {:bound, info}, state) do
    Logger.debug("(context = :up) :bound info: #{inspect(info)}")

    configure(state, info)
  end

  ## I am not sure if :expire and :stop should be here, but they were here before, so I just left them.
  defp consume(:up, {event, info}, state)
       when event in [:renew, :rebind, :reboot, :release, :expire, :stop] do
    Logger.debug("(context = :up) #{inspect(event)} info: #{inspect(info)}")

    configure(state, info)
    |> goto_context(:up)
  end

  # ********************************************************************************************* #
  # ****************************** LEGACY FUNCTIONS START *************************************** #
  # The following functions may or may not get called. They were inherited from the developers
  # at Nerves. They will never be called by Nerves.Network.Dhclientv4. We could maybe delete them??
  # ********************************************************************************************* #
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

  ## not related to Nerves.Network.Dhclientv4.
  defp consume(:down, :ifadded, state), do: state

  defp consume(:down, reason = :ifremoved, state) do
    state
    |> stop_dhclient(reason)
    |> goto_context(:removed)
  end

  ## Neither of these should be called. Not related to Nerves.Network.Dhclientv4.
  defp consume(:dhcp, {:deconfig, _info}, state), do: state

  defp consume(:dhcp, {_reason = :leasefail, _info}, state) do
    state
    |> start_link_local() # Let's configure the link-local 169.254.x.y address
    |> goto_context(:up)
  end

  ## Not related to Nerves.Network.Dhclientv4.
  defp consume(:up, {:leasefail, _info}, state), do: state

  defp consume(:up, :dhcp_retry, state) do
    state
    |> start_dhclient
    |> goto_context(:dhcp)
  end

  # ********************************************************************************************* #
  # ****************************** LEGACY FUNCTIONS END **************************************** #
  # ******************************************************************************************** #

  # Catch-all handler for consume
  defp consume(context, event, state) do
    Logger.warning("Unhandled event #{inspect(event)} for context #{inspect(context)} in consume/3.")
    state
  end

  # When the netmask is empty (no such entry in the leases DB fetch the netmask information directly from
  # network interface
  defp obtain_prefix_len(ifname, _subnet_mask = "") do
    {:ok, %{ipv4_subnet_mask: subnet_mask}} = Nerves.NetworkInterface.settings(ifname)

    subnet_mask
    |> Nerves.Network.Utils.subnet_to_prefix_len()
  end

  defp obtain_prefix_len(_ifname, subnet_mask) do
    subnet_mask
    |> Nerves.Network.Utils.subnet_to_prefix_len()
  end

  # When there's no entry of leased  ipv4_address in the leases DB fetch the address information directly from
  # the network interface
  defp obtain_ipv4_address(ifname, _ipv4_address = "") do
    {:ok, %{ipv4_address: address}} = Nerves.NetworkInterface.settings(ifname)

    address
  end

  defp obtain_ipv4_address(_ifname, address) do
    address
  end

  # Yes gateway is pingable
  def deconfigure_if_gateway_not_pingable({:ok, _host, _address, _reply_addr, _details, _payload}, state, _info) do
    Logger.debug("Gateway pingable - leaving the leased configuration...")
    Logger.debug("  state = #{inspect state}")

    state
    |> goto_context(:dhcp)
  end


  def deconfigure_if_gateway_not_pingable(_, state, info) do
    Logger.debug("Gateway unpingable - deconfiguring interface #{state.ifname}...")

    %{ipv4_address: ipv4_address, ipv4_subnet_mask: subnet_mask} = info

    prefix_len = obtain_prefix_len(state.ifname, subnet_mask) |> to_string()
    address    = obtain_ipv4_address(state.ifname, ipv4_address)

    Logger.info("-ipv4_address #{inspect address}:#{inspect prefix_len}")

    Nerves.NetworkInterface.setup(state.ifname, %{:"-ipv4_address" => "#{address}:#{prefix_len}"})

    state
    |> goto_context(:dhcp)
  end

  def deconfigure_if_gateway_not_pingable(state, info = %{ipv4_gateway: ipv4_gateway}) when is_binary(ipv4_gateway) do
    ipv4_gateway
    |> to_charlist()
    |> :gen_icmp.ping([ttl: 1, timeout: 3000, timestamp: false])
    |> Enum.at(0, {:error, :unknown})
    |> deconfigure_if_gateway_not_pingable(state, info)
  end

  def stop_dhclient(state, reason \\ :unknown) do
    Logger.debug("reason = #{inspect reason} ; state = #{inspect state}")

    if is_pid(state.dhcp_pid) do
      Nerves.Network.Dhclientv4.stop(state.dhcp_pid, reason)
      %Nerves.Network.DHCPManager{state | dhcp_pid: nil}
    else
      state
    end
  end

  def start_dhclient(state) do
    state = stop_dhclient(state, :init)
    {:ok, pid} = Nerves.Network.Dhclientv4.start_link({state.ifname, state.settings[:ipv4_dhcp]})
    %Nerves.Network.DHCPManager{state | dhcp_pid: pid}
  end

  defp setup(ifname, opts) do
    res = Nerves.NetworkInterface.setup(ifname, opts)
    {res, opts}
  end

  defp start_link_local(state) do
    with {:ok, ifstatus} <- Nerves.NetworkInterface.status(state.ifname),
         {:ok, opts} <- setup(state.ifname, ipv4_address: generate_link_local(ifstatus.mac_address)),
         {:ok, settings} <- Nerves.NetworkInterface.settings(state.ifname) do

      ip = opts[:ipv4_address]
      scope(state.ifname)
      |> SystemRegistry.update(%{ipv4_address: ip})

      Logger.info("Notifying of link-local: #{inspect settings}")
      notify(Nerves.NetworkInterface, state.ifname, :ifchanged, Map.put(settings, :ifname, state.ifname))
    else
      err -> Logger.error("Error while notifying about link-local #{inspect err}")
    end

    state
  end

  defp setup_iface(state, info) do
    case Nerves.NetworkInterface.setup(state.ifname, info) do
      :ok ->
        notify(Nerves.NetworkInterface, state.ifname, :ifchanged, info)
        :ok

      {:error, :eexist} ->
        :ok

        # It may very often happen that at the renew time we would receive the lease of the very same IP address...
        # In such a case whilst adding already existent IP address to the network interface we shall receive 'error exists'.
        # It definitely is non-critical situation and actually confirms that we do not have to take any action.
    end
  end

  defp remove_old_ip(state, info) do
    new_ip = info[:ipv4_address] || ""

    Logger.debug("info = @{inspect info}")

    # It appears that on events like EXPIRE there is not old IP address being sent withing the 'info' parameter
    with {:ok, %{:ipv4_address => old_ip, :ipv4_subnet_mask => subnet_mask}} <- Nerves.NetworkInterface.settings(state.ifname) do
      if old_ip == "" or new_ip == old_ip do
        Logger.debug("Doing nothing old_ip = #{old_ip}; new_ip = #{new_ip}")
       :ok
     else
        Logger.debug("Removing ipv4 address = #{inspect(old_ip)} from #{inspect(state.ifname)}")

        prefix_len = obtain_prefix_len(state.ifname, subnet_mask) |> to_string()
        Nerves.NetworkInterface.setup(state.ifname, %{:"-ipv4_address" => "#{old_ip}:#{prefix_len}"})
      end
    else
      err -> Logger.warning("Unable to fetch settings for #{inspect info[:ifname]} err = #{inspect err}")
    end

    :ok
  end

  defp configure(state, info) do
    Logger.debug("DHCP state #{inspect(state)} #{inspect(info)}")

    remove_old_ip(state, info)
    :ok = setup_iface(state, info)
    :ok = Nerves.Network.Resolvconf.setup(Nerves.Network.Resolvconf, state.ifname, info)

    # Show that the route has been updated
    System.cmd("ip", ["route", "show", "dev", state.ifname]) |> elem(0) |> Logger.debug()
    state
  end

  defp flush_resolv_conf_on_deconfig?() do
    [ipv4: runtime] = Application.get_env(:nerves_network, :dhclientv4, [])

    if Keyword.has_key?(runtime, :flush_resolv_conf) do
      Keyword.get(runtime, :flush_resolv_conf)
    else
      false
    end
  end

  defp deconfigure(state) do
    Logger.debug("state = #{inspect(state)}")

    if flush_resolv_conf_on_deconfig?() do
      Logger.debug("Clearing IPv4 resolver settings...")
      # Let's clear the IPv4 DHCP settings only
      :ok = Nerves.Network.Resolvconf.set_domain(Nerves.Network.Resolvconf, state.ifname, "")
      :ok = Nerves.Network.Resolvconf.set_nameservers(Nerves.Network.Resolvconf, state.ifname, [])
    end

    state
  end
end
