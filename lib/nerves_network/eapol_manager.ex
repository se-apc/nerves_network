################################################################
# Copyright (C) 2022 Schneider Electric                        #
################################################################

defmodule Nerves.Network.EAPoLManager do

  @moduledoc """
  A module that wraps wpa_supplicant in order to provide the EAPoL service.
  """

  use GenServer
  import Nerves.Network.Utils
  alias Nerves.Network.Types

  require EEx
  require Logger

  @typep context :: Types.interface_context() | :dhcp

  @typedoc "State of the GenServer."
  @type t :: %{
    context: context,
    ifname: Types.ifname | nil,
    settings: Nerves.Network.setup_settings | nil,
    dhcp_pid: GenServer.server | nil,
    wpa_pid: GenServer.server | nil
  }

  #  defstruct context: :removed,
  #            ifname: nil,
  #            settings: nil,
  #            dhcp_pid: nil,
  #            wpa_pid: nil

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
    #{:ok, _} = Registry.register(Nerves.Network.Dhclientv4, ifname, [])
    #{:ok, _} = Registry.register(Nerves.Network.Dhclient, ifname, [])

    Logger.info "Done Registering"
    state = %{settings: settings, ifname: ifname, wpa_pid: nil, wpa_ctrl_iface: @wpa_control_path}

    # If the interface currently exists send ourselves a message that it
    # was added to get things going.
    #current_interfaces = Nerves.NetworkInterface.interfaces()
    #state =
    #  if Enum.member?(current_interfaces, ifname) do
    #    consume(state.context, :ifadded, state)
    #  else
    #    state
    #  end

    {:ok, state}
  end

  @spec stop_wpa(t) :: t
  def stop_wpa(state) do
    if is_pid(state.wpa_pid) do
      Nerves.WpaSupplicant.stop(state.wpa_pid)
      %{state | wpa_pid: nil}
    else
      state
    end
  end

  defp parse_settings(settings) when is_list(settings) do
    settings
    |> Map.new()
    |> parse_settings()
  end

  defp parse_settings(settings = %{ key_mgmt: key_mgmt }) when is_binary(key_mgmt) do
    %{ settings | key_mgmt: String.to_atom(key_mgmt) }
    |> parse_settings()
  end

  # Detect when the use specifies no WiFi security but supplies a
  # key anyway. This confuses wpa_supplicant and causes the failure
  # described in #39.
  defp parse_settings(settings = %{ key_mgmt: :NONE, psk: _psk }) do
    Map.delete(settings, :psk)
    |> parse_settings
  end

  defp parse_settings(settings), do: settings

  #    ctrl_interface=DIR=<%= @wpa_ctrl_iface %> GROUP=wheel
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

    if !File.exists?(wpa_control_pipe(state)) do
        # wpa_supplicant daemon not started, so launch it
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
          :ok
        else
          {:error, reason} ->
            Logger.error("Unable to write #{wpa_config_file(state)} wpa_supplicant!")
          {output, error_code} ->
            Logger.error("#{@wpa_supplicant} exitted with #{inspect error_code} output = #{output}!")
        end
    end

    {:ok, pid} = Nerves.WpaSupplicant.start_link(state.ifname, wpa_control_pipe(state), name: :"Nerves.WpaSupplicant.#{state.ifname}")
    Logger.info "Register Nerves.WpaSupplicant #{inspect state.ifname}"
    {:ok, _} = Registry.register(Nerves.WpaSupplicant, state.ifname, [])
    #    wpa_supplicant_settings = parse_settings(state.settings)
    #    case Nerves.WpaSupplicant.set_network(pid, wpa_supplicant_settings) do
    #      :ok -> :ok
    #      error ->
    #        Logger.info "EAPoLManager(#{state.ifname}, #{state.context}) wpa_supplicant set_network error: #{inspect error}"
    #        notify(Nerves.WpaSupplicant, state.ifname, error, %{ifname: state.ifname})
    #    end

    %{state | wpa_pid: pid}
  end

  # if the wpa_pid is nil, we don't want to actually create the call.
  def handle_call(:start, _from, state) do
    retval = start_wpa(state)
    Logger.info("start_wpa returned #{inspect retval} state = #{inspect state}")
    {:reply, retval, state}
  end

  def handle_call({:start, args}, _from, state) do
    state = Map.merge(state, args)
    retval = start_wpa(state)
    Logger.info("start_wpa returned #{inspect retval} state = #{inspect state}")
    {:reply, retval, state}
  end

  def handle_info(event, s) do
    Logger.info "{s.ifname}): ignoring event: #{inspect event}"
    {:noreply, s}
  end
end
