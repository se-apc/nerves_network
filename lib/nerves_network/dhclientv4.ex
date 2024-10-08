# Copyright 2014 LKC Technologies, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule Nerves.Network.Dhclientv4 do
  use GenServer
  require Logger
  alias Nerves.Network.Utils

  @release 2
  @terminate 3

  @moduledoc """
  This module interacts with `dhclient` to interact with DHCP servers.
  """

  def start_link(args), do: start_link(__MODULE__, args)

  @doc """
  Start and link a Dhclientv4 process for the specified interface (i.e., eth0,
  wlan0).
  """
  def start_link(_modname, args) do
    Logger.debug("#{__MODULE__}: Dhclientv4 starting for args: #{inspect(args)}")
    GenServer.start_link(__MODULE__, args)
  end

  @doc """
  Notify the DHCP server to release the IP address currently assigned to
  this interface. After calling this, be sure to disassociate the IP address
  from the interface so that packets don't accidentally get sent or processed.
  """
  def release(pid) do
    Logger.debug(":release")
    GenServer.call(pid, :release)
  end

  @doc """
  Renew the lease on the IP address with the DHCP server.
  """
  def renew(pid) do
    Logger.debug(":renew")
    GenServer.call(pid, :renew)
  end

  defp do_stop(nil, pid, reason) do
    Logger.debug("No such process #{inspect pid}; reason = #{inspect reason}")
  end

  defp do_stop(pinfo, pid, reason) do
    Logger.debug("Process info = #{inspect pinfo}; pid = #{inspect pid}; reason = #{inspect reason}")

    GenServer.stop(pid, reason)
  end

  @doc """
  Stop the dhcp client
  """
  def stop(pid, reason \\ :unknown) do
    Logger.debug("Dhclientv4.stop pid: #{inspect(pid)}; reason = #{inspect reason}")

    Process.info(pid, [:reductions, :memory, :message_queue_len])
    |> do_stop(pid, reason)
  end

  defp append_ifname(input_str, ifname) do
    input_str <> "." <> ifname
  end

  defp runtime_config_file(ifname, runtime) do
    if Keyword.has_key?(runtime, :config_file) do
      ["-cf", runtime_config_file_path(ifname, runtime)]
    else
      []
    end
  end

  defp runtime_lease_file(ifname, runtime) do
    if Keyword.has_key?(runtime, :lease_file) do
      ["-lf", runtime_lease_file_path(ifname, runtime)]
    else
      []
    end
  end

  defp runtime_config_file_path(_ifname, runtime) do
    #Config file contains entries for all managed interfaces
    Keyword.get(runtime, :config_file)
  end

  defp runtime_lease_file_path(ifname, runtime) do
    Keyword.get(runtime, :lease_file) |> append_ifname(ifname)
  end

  defp runtime_pid_file(ifname, runtime) do
    if Keyword.has_key?(runtime, :pid_file) do
      ["-pf", Keyword.get(runtime, :pid_file) |> append_ifname(ifname)]
    else
      []
    end
  end

  # Parsing config.exs entry of the following format: [dhclient: [lease_file: "/var/lib/dhclient4.leases", pid_file: "/var//run/dhclient4.pid"]]
  defp dhclient_runtime(ifname) do
    runtime = runtime()

    Logger.debug("runtime options = #{inspect(runtime)}")

    runtime_lease_file(ifname, runtime)
      ++ runtime_pid_file(ifname, runtime)
      ++ runtime_config_file(ifname, runtime)
  end

  defp runtime() do
    [ipv4: runtime] = Application.get_env(:nerves_network, :dhclientv4, [])
    runtime
  end

  def init(args) do
    {ifname, mode} = args

    Logger.info(
      "Starting Dhclientv4 wrapper for ifname: #{inspect(ifname)} mode: #{
        inspect(mode)
      }"
    )

    priv_path = :code.priv_dir(:nerves_network)
    port_path = "#{priv_path}/dhclientv4_wrapper"

    # This is a workaround to handle the case where we change networks
    if Application.get_env(:nerves_network, :flush_lease_db) do
      runtime_lease_file_path(ifname, runtime())
      |> to_string()
      |> File.rm()
    end

    args =
      [
        "dhclient",
        # ipv4
        "-4",
        # The script to be invoked at the lease time
        "-sf",
        port_path,
        "-v",
        "-d"
      ] ++ dhclient_runtime(ifname) ++ [ifname]

    port =
      Port.open(
        {:spawn_executable, port_path},
        [{:args, args}, :exit_status, :stderr_to_stdout, {:line, 256}]
      )

    Logger.info("Dhclientv4 port: #{inspect(port)}; args: #{inspect(args)}")

    {:ok, %{ifname: ifname, port: port, running: true}}
  end

  def terminate(_reason, state = %{running: true}) do
    # Send the command to our wrapper to shut everything down.
    Logger.debug("terminate...")
    Port.command(state.port, <<@terminate>>)
    Port.close(state.port)
    :ok
  end

  def terminate(_reason, _state) do
    :ok
  end


  def handle_call(:renew, _from, state) do
    Logger.debug(":renew")

    {:reply, :ok, state}
  end

  # A dummy handler for a :timeout call
  def handle_call(:timeout, _from, state) do
    Logger.debug(":timeout")
    {:reply, :ok, state}
  end

  def handle_call(:release, _from, state) do
    Port.command(state.port, <<@release>>)
    {:reply, :ok, state}
  end

  def handle_call(reason, _from, state) do
    Logger.debug("reason = #{inspect reason}; state = #{inspect state}")
    {:reply, :ok, state}
  end

  #  Nerves.Network.Dhclientv4.handle_info({#Port<0.6423>, {:exit_status, 0}}, %{ifname: "eth1", port: #Port<0.6423>})
  def handle_info({_pid, {:exit_status, exit_status}}, state) do
    Logger.error(
      "dhclientv4 exited: exit_status = #{inspect(exit_status)}, state = #{inspect(state)}"
    )

    {:stop, :exit, %{state | running: false}}
  end

  def handle_info({_, {:data, {:eol, message}}}, state) do
    handle(message, state)
  end

  def handle(message, state) do
    message
    |> List.to_string()
    |> String.split(",")
    |> handle_dhclient(state)
  end

  @typedoc "State of the GenServer."
  @type state :: %{ifname: Types.ifname(), port: port}

  @typedoc "Message from the dhclientv4 port."
  # we can do better.
  @type dhclientv4_wrapper_event :: [...]

  @typedoc "Event from the dhclientv4 server to be sent via SystemRegistry."
  @type event :: :deconfig
  | :bound
  | :renew
  | :leasefail
  | :expire
  | :reboot
  | :nak
  | :ifdown
  | :ifup
  | :timeout

  @spec notify(list(), event(), map()) :: map()
  defp notify([ifname, ip, broadcast, subnet, router, domain, dns | _other_options], event, state) do
    dnslist = String.split(dns, " ")

    map =
      %{
        ifname: ifname,
        ipv4_address: ip,
        ipv4_broadcast: broadcast,
        ipv4_subnet_mask: subnet,
        ipv4_gateway: router,
        domain: domain,
        nameservers: dnslist
      }

    Logger.debug("dhclientv4: Notifying about event #{inspect event}: #{inspect map}")

    Utils.notify(Nerves.Dhclientv4, state.ifname, event, map)
  end

  @spec handle_dhclient(dhclientv4_wrapper_event, state) :: {:noreply, state}
  defp handle_dhclient(["deconfig", ifname | _rest], state) do
    Logger.debug("dhclientv4: deconfigure #{ifname}")

    {:noreply, state}
  end

  #[debug] Nerves.Network.Dhclientv4.handle_dhclient/2 : Received reason 'TIMEOUT; options = ["eth0", "10.216.251.86", "10.216.251.127", "255.255.255.128", "10.216.251.1", "eur.gad.schneider-electric.com", "10.156.118.9 10.198.90.15"]'. Not performing any update to network interface.
  defp handle_dhclient([reason | options], state) when reason in ["MEDIUM", "ARPCHECK", "ARPSEND"] do
    Logger.debug("Received reason '#{reason}; options = #{inspect options}'. Not performing any update to network interface.")

    {:noreply, state}
  end

  # TIMEOUT event is usually followed by the (lease)FAIL
  defp handle_dhclient([reason = "TIMEOUT" | options], state) do
    Logger.debug("dhclientv4: Received reason '#{reason}' options = #{inspect options}")

    notify(options, :timeout, state)

    {:noreply, state}
  end

  defp handle_dhclient([reason = "BOUND" | options], state) do
    Logger.debug("dhclientv4: Received reason '#{reason}'")

    notify(options, :bound, state)

    {:noreply, state}
  end

  defp handle_dhclient([reason = "REBOOT" | options], state) do
    Logger.debug("dhclientv4: Received reason '#{reason}'")

    notify(options, :reboot, state)

    {:noreply, state}
  end

  defp handle_dhclient([reason = "RENEW" | options], state) do
    Logger.debug("dhclientv4: Received reason '#{reason}'")

    notify(options, :renew, state)

    {:noreply, state}
  end

  defp handle_dhclient([reason = "REBIND" | options], state) do
    Logger.debug("dhclientv4: Received reason '#{reason}'")

    notify(options, :rebind, state)

    {:noreply, state}
  end


  defp handle_dhclient([reason = "PREINIT" | options], state) do
    Logger.debug("dhclientv4:  Received reason '#{reason}'. Bringing interface up.")

    notify(options, :ifup, state)

    {:noreply, state}
  end

  defp handle_dhclient([reason = "EXPIRE" | options], state) do
    Logger.debug("dhclientv4: Received reason '#{reason}'. Reconfiguring interface.")

    notify(options, :expire, state)

    {:noreply, state}
  end

  defp handle_dhclient([reason | options], state) when reason in ["FAIL"] do
    Logger.debug("dhclientv4: Received reason '#{reason}'.")

    notify(options, :leasefail, state)

    {:noreply, state}
  end

  defp handle_dhclient([reason | options], state) when reason in ["RELEASE", "STOP"] do
    Logger.debug("dhclientv4: Received reason '#{reason}'. Bringing interface down.")

    notify(options, :ifdown, state)

    {:noreply, state}
  end

  # Handling informational debug prints from the dhclient
  defp handle_dhclient([message], state) do
    Logger.debug("handle_dhclient args = #{inspect(message)} state = #{inspect(state)}")

    {:noreply, state}
  end

  defp handle_dhclient(something_else, state) do
    msg = List.foldl(something_else, "", &<>/2)
    Logger.debug("dhclient: ignoring unhandled message: #{msg}")
    {:noreply, state}
  end
end
