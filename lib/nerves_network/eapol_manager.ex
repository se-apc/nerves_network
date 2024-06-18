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
          ifname: Types.ifname() | nil,
          settings: Nerves.Network.setup_settings() | nil,
          dhcp_pid: GenServer.server() | nil,
          wpa_pid: GenServer.server() | nil,
          supplicant_port: GenServer.server() | nil
        }

  @type setup() :: %{
          :ssid => String.t(),
          :identity => String.t(),
          :ca_cert => String.t(),
          :client_cert => String.t(),
          :private_key => String.t(),
          :private_key_passwd => String.t() | nil
        }

  @wpa_supplicant_path Application.compile_env(:nerves_network, :eapolmanager, [])[:wpa_supplicant_path] || @default_wpa_supplicant_path
  @wpa_control_path Application.compile_env(:nerves_network, :eapolmanager, [])[:wpa_control_path] || @default_wpa_control_path
  @wpa_config_file_prefix Application.compile_env(:nerves_network, :eapolmanager, [])[:wpa_config_file_prefix] || @default_wpa_config_file_prefix

  @doc false
  @spec start_link(Types.ifname(), Nerves.Network.setup_settings(), GenServer.options()) :: GenServer.on_start()
  def start_link(ifname, settings, opts \\ []) do
    GenServer.start_link(__MODULE__, {ifname, settings}, opts)
  end

  defp registry_register(registry_name, ifname) do
    case Registry.register(registry_name, ifname, []) do
      {:ok, _pid} ->
        Logger.debug("Succesfuly registered #{ifname} to #{inspect(registry_name)}")

      {:error, {:already_registered, _pid}} ->
        Logger.warning("Already registered #{ifname} to #{inspect(registry_name)}")
    end
  end

  def init({ifname, settings}) do
    # Make sure that the interface is enabled or nothing will work.
    Logger.info("EAPoLManager(#{ifname}) starting")
    Logger.info("Register Nerves.NetworkInterface #{inspect(ifname)}")

    # Register for nerves_network_interface events and udhcpc events
    :ok = registry_register(Nerves.NetworkInterface, ifname)
    Registry.start_link(keys: :duplicate, name: __MODULE__)

    Logger.info("Done Registering")

    state = %{
      settings: settings,
      ifname: ifname,
      wpa_pid: nil,
      supplicant_port: nil,
      wpa_ctrl_iface: @wpa_control_path
    }

    {:ok, state}
  end

  @spec stop_wpa(t) :: t
  defp stop_wpa(state) do
    if is_pid(state.wpa_pid) do
      Nerves.WpaSupplicant.stop(state.wpa_pid, state.supplicant_port)

      if(Registry.count(Nerves.WpaSupplicant) > 0) do
        Logger.debug("Unregistering Nerves.WpaSupplicant...")
        _ = Registry.unregister(Nerves.WpaSupplicant, state.ifname)
      end

      # A grace period for the OS to clean after wpa_supplicant process
      :timer.sleep(250)

      %{state | wpa_pid: nil, supplicant_port: nil}
    else
      Logger.debug("stop_wpa: state.wpa_pid not pid!")
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

  defp start_supplicant_port(state) do
    port =
      Port.open(
        {:spawn_executable, @wpa_supplicant_path},
        [
          {:args,
           [
             "-i#{state.ifname}",
             "-c#{wpa_config_file(state)}",
             "-Dwired"
           ]},
          {:packet, 2},
          :binary,
          :exit_status
        ]
      )

    port
  end

  defp wait_for_file(name, step_ms, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    if !File.exists?(name) do
      :timer.sleep(step_ms)
      wait_for_file(name, step_ms, timeout_ms - step_ms)
    else
      :ok
    end
  end

  defp wait_for_file(_name, _step_ms, timeout_ms) when is_integer(timeout_ms) and timeout_ms <=  0 do
    :timeout
  end

  defp start_wpa_supervisor(state) do
    child =
      Supervisor.child_spec(
        {Nerves.WpaSupplicant,
         [
           state.ifname,
           wpa_control_pipe(state),
           :permanent,
           [name: :"Nerves.WpaSupplicant.#{state.ifname}"]
         ]},
        id: :"Nerves.WpaSupplicant.#{state.ifname}",
        restart: :transient
      )

    {:ok, pid} = Supervisor.start_link([child], strategy: :one_for_one)
    [child] = Supervisor.which_children(pid)

    {_name, pid, _type, _module} = child
    pid
  end

  @spec start_wpa(t()) :: t()
  defp start_wpa(state) do
    state = stop_wpa(state)

    # The WPA control pipe should not exist. It may appen though that process ends abruptly i.e. SIGSEGV or sigkill 9.
    if File.exists?(wpa_control_pipe(state)) do
      case File.rm(wpa_control_pipe(state)) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("Unable to remove #{wpa_control_pipe(state)} reason: #{inspect reason}")
      end
    end

    with :ok <- write_wpa_conf(state) do
      port = start_supplicant_port(state)

      # give it time to open the pipe
      wpa_control_pipe(state)
      |> wait_for_file(111, 3_333)
      |> case do
        :ok ->
          Logger.debug("Control pipe exists. Starting wpa_ex...")
        :timeout ->
          Logger.warning("WPA control pipe #{inspect wpa_control_pipe(state)} not created on time!")
      end

      pid = start_wpa_supervisor(state)

      :ok = registry_register(Nerves.WpaSupplicant, state.ifname)

       %{state | supplicant_port: port, wpa_pid: pid}
    else
      {:error, reason} ->
        Logger.error(
          "Unable to write #{wpa_config_file(state)} wpa_supplicant reason = #{inspect(reason)}!"
        )

        state

      {output, error_code} ->
        Logger.error(
          "#{@wpa_supplicant_path} exited with #{inspect(error_code)} output = #{output}!"
        )

        state
    end
  end

  # if the wpa_pid is nil, we don't want to actually create the call.
  def handle_call(:start, _from, state) do
    retval = start_wpa(state)
    {:reply, retval, retval}
  end

  def handle_call(:stop, _from, state) do
    retval = stop_wpa(state)
    {:reply, retval, retval}
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:setup, args}, _from, state) do
    with retval <- Map.merge(state, args),
         :ok <- write_wpa_conf(retval) do
      {:reply, :ok, retval}
    else
      {:error, reason} ->
        Logger.error(
          "Unable to write #{wpa_config_file(state)} wpa_supplicant reason = #{inspect(reason)}!"
        )

        {:reply, {:error, reason}, state}
    end
  end

  # args =
  #  %{
  #  :ssid => "eth0-eapol",
  #  :identity => "user@example.org",
  #  :ca_cert => "/var/system/pub/eapol/ca.pem",
  #  :client_cert => "/var/system/pub/eapol/user@example.org.pem",
  #  :private_key => "/var/system/priv/eapol/user@example.org.key",
  #  :private_key_passwd => "whatever"
  # }
  def handle_call({:start, args}, _from, state) do
    retval =
      Map.merge(state, args)
      |> start_wpa()

    {:reply, retval, retval}
  end

  def handle_call(:reconfigure, _from, state = %{wpa_pid: wpa_pid}) when is_pid(wpa_pid) do
    retval = Nerves.WpaSupplicant.reconfigure(state.wpa_pid)

    {:reply, retval, state}
  end

  def handle_call(:reconfigure, _from, state = %{wpa_pid: _wpa_pid}) do
    Logger.warning("WPA is not started - skipping :reconfigure")

    {:reply, {:error, :not_started}, state}
  end

  def handle_call(unknown, _from, state) do
    Logger.warning("Unknown call #{inspect(unknown)}")

    {:reply, :ok, state}
  end

  def handle_info(
        _event =
          {Nerves.WpaSupplicant, e = {:"CTRL-EVENT-DISCONNECTED", _mac, _map}, %{ifname: _ifname}},
        s
      ) do
    Logger.info("Event received: #{inspect(e)}")

    {:noreply, s}
  end

  # Called on wpa_ex port's exit. A subscriber to it is responsible to call GenServer with :start or {:start, setup}, if needed.
  def handle_info(
        event = {Nerves.WpaSupplicant, e = {:terminated, :unexpected_exit}, %{ifname: ifname}},
        s
      ) do
    Logger.info("Forwarding event = #{inspect(event)}")

    Utils.notify(__MODULE__, ifname, e, %{ifname: ifname})
    {:noreply, %{s | wpa_pid: nil}}
  end

  #Handling events like:  {:"CTRL-REQ-PASSPHRASE", 0, "Private key passphrase needed for SSID nmc-eapol-eth0"}, %{ifname: "eth0"}}
  def handle_info(event = {Nerves.WpaSupplicant, {id, net_id, message}, %{ifname: ifname}}, s) do
    Logger.info("Forwarding event = #{inspect(event)}")

    Utils.notify(__MODULE__, ifname, {id, net_id, message}, %{ifname: ifname})
    {:noreply, s}
  end

  def handle_info(event = {Nerves.WpaSupplicant, {id, message}, %{ifname: ifname}}, s) do
    Logger.info("Forwarding event = #{inspect(event)}")

    Utils.notify(__MODULE__, ifname, {id, message}, %{ifname: ifname})
    {:noreply, s}
  end

  # Handling events like: {Nerves.WpaSupplicant, :"CTRL-EVENT-TERMINATING", %{ifname: "eth0"}} and
  # forwarding them as uniform "{:"CTRL-EVENT-TERMINATING", ""}
  def handle_info(event = {Nerves.WpaSupplicant, id, %{ifname: ifname}}, s) when is_atom(id) do
    Logger.info("Forwarding event = #{inspect(event)}")

    Utils.notify(__MODULE__, ifname, {id, ""}, %{ifname: ifname})
    {:noreply, s}
  end

  # Will be called on wpa_supplicant's port's exit. It may come asynchronously, so if stop is being invoked
  # from the :start call, we would not like to interfere with the state machine - maintaining the state.
  # In particular we do not want to touch the :supplicant_port field of the state map.
  def handle_info({_pid, {:exit_status, exit_status = 0}}, state) do
    Logger.warning("Exit status #{inspect(exit_status)}. It's O.K.")

    {:noreply, state}
  end

  def handle_info({_pid, {:exit_status, exit_status}}, state) do
    # IF exited abnormaly - exit code != 0 then we shall attempt to restart the wpa_supplicant and associated ports
    Logger.warning("Exit status #{inspect(exit_status)}. Re-starting...")
    {:noreply, start_wpa(%{state | supplicant_port: nil})}
  end

  def handle_info(event, s) do
    Logger.info("#{s.ifname}): ignoring event: #{inspect(event)}")

    {:noreply, s}
  end

  def terminate(reason, state) do
    Logger.warning("#{__MODULE__} Terminating... reason: #{inspect reason}")

    # We are emitting a Nerves.Network.EAPoLManager's termination event so it could eventually get re-started
    Utils.notify(__MODULE__, state.ifname, {:terminating, __MODULE__}, %{ifname: state.ifname})
    stop_wpa(state)
  end

  @doc """
  Starts EAPoL service on `ifname` interface with the given `setup`configuration
  If WPA service had already been started it gets restarted.

  Returns `EAPoLManager.t()`.

  ## Parameters
  - ifname: String.t() i.e. "eth0"
  - setup: EAPoLManager.setup()

  ## Examples

    iex> setup = %{
    ...>    :ssid => "eth0-eapol",
    ...>    :identity => "user@example.org",
    ...>    :ca_cert => "/var/system/pub/eapol/ca.pem",
    ...>    :client_cert => "/var/system/pub/eapol/user@example.org.pem",
    ...>    :private_key => "/var/system/priv/eapol/user@example.org.key",
    ...>    :private_key_passwd => "whatever"
    ...>  }
    iex> retval = Nerves.Network.EAPoLManager.start("eth0", setup)
    iex> is_map(retval)
    true

    iex> setup = %{
    ...>    :ssid => "eth0-eapol",
    ...>    :identity => "user@example.org",
    ...>    :ca_cert => "/var/system/pub/eapol/ca.pem",
    ...>    :client_cert => "/var/system/pub/eapol/user@example.org.pem",
    ...>    :private_key => "/var/system/priv/eapol/user@example.org.key",
    ...>    :private_key_passwd => "whatever"
    ...>  }
    iex> :ok = Nerves.Network.EAPoLManager.setup("eth0", setup)
    iex> retval = Nerves.Network.EAPoLManager.start("eth0")
    iex> is_map(retval)
    true

  """
  def start(ifname, setup) do
    GenServer.call(:"Elixir.Nerves.Network.EAPoLManager.#{ifname}", {:start, setup})
  end

  def start(ifname) do
    GenServer.call(:"Elixir.Nerves.Network.EAPoLManager.#{ifname}", :start)
  end

  @doc """
  Stops EAPoL service on `ifname` interface.

  Returns `EAPoLManager.t()`.

  ## Parameters
  - ifname: String.t() i.e. "eth0"

  ## Examples

    iex> retval = Nerves.Network.EAPoLManager.stop("eth0")
    iex> is_map(retval)
    true

  """
  def stop(ifname) do
    GenServer.call(:"Elixir.Nerves.Network.EAPoLManager.#{ifname}", :stop)
  end

  @doc """
  Returns current state of EAPoLManager for a given interface.

  Returns `EAPoLManager.t()`.

  ## Parameters
  - ifname: String.t() i.e. "eth0"

  ## Examples

    iex> retval = Nerves.Network.EAPoLManager.state("eth0")
    iex> is_map(retval)
    true

  """
  def state(ifname) do
    GenServer.call(:"Elixir.Nerves.Network.EAPoLManager.#{ifname}", :state)
  end

  @doc """

  Returns `setup`.
  Changes the WPA supplicant's configuration and writes the run-time config. The changes will not take affect, until either of:
  - WPA is restarted: stop(ifname), start(ifname)
  - reconfigure(ifname) call
  ## Parameters
  - ifname: String.t() i.e. "eth0"
  - setup: i.e.:
  %{
  :ssid => "eth0-eapol",
  :identity => "user@example.org",
  :ca_cert => "/var/system/pub/eapol/ca.pem",
  :client_cert => "/var/system/pub/eapol/user@example.org.pem",
  :private_key => "/var/system/priv/eapol/user@example.org.key",
  :private_key_passwd => "whatever"
  }

  ## Examples

    iex> cfg = %{
    ...>    :ssid => "eth0-eapol",
    ...>    :identity => "user@example.org",
    ...>    :ca_cert => "/var/system/pub/eapol/ca.pem",
    ...>    :client_cert => "/var/system/pub/eapol/user@example.org.pem",
    ...>    :private_key => "/var/system/priv/eapol/user@example.org.key",
    ...>    :private_key_passwd => "whatever"
    ...>  }
    iex> Nerves.Network.EAPoLManager.setup("eth0", cfg)
    :ok

  """
  def setup(ifname, setup) do
    GenServer.call(:"Elixir.Nerves.Network.EAPoLManager.#{ifname}", {:setup, setup})
  end

  @doc """
  Brings the current configuration e.g. set by EAPoLManager.setup(ifname) call into effect. The WPA supplicant must be started and
  running (EAPoLManager.start(ifname) call)  otherwise {:error, :not_started} is reported.
  The EAP authentication process get's restarted, after successful reconfiguration.

  Returns `:ok` or {:error, reason}.

  ## Parameters
  - ifname: String.t() e.g. EAPoLManager.reconfigure("eth0")

  ## Examples

  #iex> setup = %{
    #...>    :ssid => "eth0-eapol",
    #...>    :identity => "user@example.org",
    #...>    :ca_cert => "/var/system/pub/eapol/ca.pem",
    #...>    :client_cert => "/var/system/pub/eapol/user@example.org.pem",
    #...>    :private_key => "/var/system/priv/eapol/user@example.org.key",
    #...>    :private_key_passwd => "whatever"
    #...>  }
  #iex> _ = Nerves.Network.EAPoLManager.start("eth0", setup)
  iex> Nerves.Network.EAPoLManager.reconfigure("eth0")
  :ok

  """
  def reconfigure(ifname) do
    GenServer.call(:"Elixir.Nerves.Network.EAPoLManager.#{ifname}", :reconfigure)
  end
end
