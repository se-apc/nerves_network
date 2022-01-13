################################################################
# Copyright (C) 2022 Schneider Electric                        #
################################################################

defmodule Nerves.Network.EAPoLManager do

  @moduledoc """
  A module that wraps wpa_supplicant in order to provide the EAPoL service.
  """

  use GenServer
  alias Nerves.Network.Types
  alias Nerves.Network.Utils

  require EEx
  require Logger

  @typep context :: Types.interface_context() | :dhcp

  @typedoc "State of the GenServer."
  @type t :: %{
    context: context,
    ifname: Types.ifname | nil,
    settings: Nerves.Network.setup_settings | nil,
    dhcp_pid: GenServer.server | nil,
    wpa_pid: GenServer.server | nil,
  }

  # The following are Nerves locations of the supplicant. If not using
  # Nerves, these may be different.
  @wpa_supplicant_path    "/usr/sbin/wpa_supplicant"
  @wpa_control_path       "/var/run/wpa_supplicant"
  @wpa_config_file_prefix "/var/run/nerves_network_wpa_eapol.conf"

  @doc false
  @spec start_link(Types.ifname, Nerves.Network.setup_settings, GenServer.options) :: GenServer.on_start
  def start_link(ifname, settings, opts \\ []) do
    GenServer.start_link(__MODULE__, {ifname, settings}, opts)
  end

  def init({ifname, settings}) do
    # Make sure that the interface is enabled or nothing will work.
    Logger.info("EAPoLManager(#{ifname}) starting")
    Logger.info("Register Nerves.NetworkInterface #{inspect ifname}")

    # Register for nerves_network_interface events and udhcpc events
    {:ok, _} = Registry.register(Nerves.NetworkInterface, ifname, [])
    Registry.start_link(keys: :duplicate, name: __MODULE__)

    Logger.info "Done Registering"
    state = %{settings: settings, ifname: ifname, wpa_pid: nil, wpa_ctrl_iface: @wpa_control_path}

    {:ok, state}
  end

  @spec stop_wpa(t) :: t
  def stop_wpa(state) do
    if is_pid(state.wpa_pid) do
      Nerves.WpaSupplicant.stop(state.wpa_pid)

      if(Registry.count(Nerves.WpaSupplicant) > 0) do
        Logger.debug("Unregistering Nerves.WpaSupplicant...")
        _ = Registry.unregister(Nerves.WpaSupplicant, state.ifname)
      end

      # A grace priod for the OS to clean after wpa_supplicant process
      :timer.sleep 250
      %{state | wpa_pid: nil}
    else
      Logger.warn "state.wpa_pid not pid!"
      state
    end
  end

  def wpa_conf_contents(state) do
    """
    ctrl_interface=DIR=<%= @wpa_ctrl_iface %>
    network={
      ssid="<%= @ssid %>"
      key_mgmt=IEEE8021X
      eap=TLS
      identity="<%= @identity %>"
      ca_cert="<%= @ca_cert %>"
      client_cert="<%= @client_cert %>"
      private_key="<%= @private_key %>"
      <%= if assigns[:private_key_passwd] != nil and assigns[:private_key_passwd] != "" do %>
      private_key_passwd="<%= @private_key_passwd %>"
      <% end %>
      eapol_flags=0
    }
    """
    |> EEx.eval_string(assigns: state)
  end

  defp wpa_config_file(state) do
    @wpa_config_file_prefix <> ".#{state.ifname}"
  end

  @spec write_wpa_conf(t()) :: :ok | {:error, term()}
  def write_wpa_conf(state) do
    File.write(wpa_config_file(state), wpa_conf_contents(state))
  end

  @spec wpa_control_pipe(t()) :: String.t()
  defp wpa_control_pipe(state) do
    @wpa_control_path <> "/#{state.ifname}"
  end
  @spec start_wpa(t()) :: t()
  def start_wpa(state) do
    state = stop_wpa(state)

    Logger.info "State after stopping = #{inspect state}"

    #    state = wait_for_disconnect(state)

    if File.exists?(wpa_control_pipe(state)) do
      case File.rm(wpa_control_pipe(state)) do
        :ok -> :ok
        {:error, reason} ->
          Logger.error("Unable to remove #{wpa_control_pipe(state)}")
      end
    end

     with :ok <- write_wpa_conf(state),
            {_, 0} <-  System.cmd(@wpa_supplicant_path,
                          [
                            "-i#{state.ifname}",
                            "-c#{wpa_config_file(state)}",
                            "-Dwired",
                            "-B"
                          ]) do

          # give it time to open the pipe
          :timer.sleep 250

          {:ok, pid} = Nerves.WpaSupplicant.start_link(state.ifname, wpa_control_pipe(state), name: :"Nerves.WpaSupplicant.#{state.ifname}")
          Logger.info "Register Nerves.WpaSupplicant #{inspect state.ifname}"
          {:ok, _} = Registry.register(Nerves.WpaSupplicant, state.ifname, [])
          %{state | wpa_pid: pid}
        else
          {:error, reason} ->
            Logger.error("Unable to write #{wpa_config_file(state)} wpa_supplicant reson = #{inspect reason}!")
            state
          {output, error_code} ->
            Logger.error("#{@wpa_supplicant_path} exitted with #{inspect error_code} output = #{output}!")
            state
     end
  end

  # if the wpa_pid is nil, we don't want to actually create the call.
  def handle_call(:start, _from, state) do
    retval = start_wpa(state)
    Logger.info("start_wpa returned #{inspect retval} state = #{inspect state}")
    {:reply, retval, state}
  end

  def handle_call(:stop, _from, state) do
    retval = stop_wpa(state)
    Logger.info("stop_wpa returned #{inspect retval} state = #{inspect state}")
    {:reply, retval, retval}
  end

  # args =
  #  %{
  #  :ssid => "eth0-eapol",
  #  :identity => "user@example.org",
  #  :ca_cert => "/var/system/pub/eapol/ca.pem",
  #  :client_cert => "/var/system/pub/eapol/user@example.org.pem",
  #  :private_key => "/var/system/priv/eapol/user@example.org.key",
  #  :private_key_passwd => "whatever"
  #}
  def handle_call({:start, args}, _from, state) do
    retval =
      Map.merge(state, args)
      |> start_wpa()
    #state = Map.merge(retval, args)
    Logger.info("start_wpa returned #{inspect retval} state = #{inspect state}")
    {:reply, retval, retval}
  end

  def handle_info(event = {Nerves.WpaSupplicant, e = {:"CTRL-EVENT-DISCONNECTED", _mac, _map}, %{ifname: _ifname}}, s) do
    Logger.info("Event received: #{inspect e}")

    {:noreply, s}
  end

  def handle_info(event = {Nerves.WpaSupplicant, {id, message}, %{ifname: ifname}}, s) do
    Logger.info("Forwarding event = #{inspect event}")

    Utils.notify(__MODULE__, ifname, {id, message}, %{ifname: ifname})
    {:noreply, s}
  end

  # ignoring event: {Nerves.WpaSupplicant, {:"CTRL-EVENT-EAP-FAILURE", "EAP authentication failed"}, %{ifname: "eth0"}}
  def handle_info(event, s) do
    Logger.info "{s.ifname}): ignoring event: #{inspect event}"

    {:noreply, s}
  end
end
