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

defmodule Nerves.Network.Dhclient do
  use GenServer
  require Logger
  alias Nerves.Network.Utils

  @renew     1
  @release   2
  @terminate 3

  @moduledoc """
  This module interacts with `dhclient` to interact with DHCP servers.
  """

  def start_link(args), do: start_link(__MODULE__, args)

  @doc """
  Start and link a Dhclient process for the specified interface (i.e., eth0,
  wlan0).
  """
  def start_link(_modname, args) do
    Logger.debug fn -> "#{__MODULE__}: Dhclient starting for args: #{inspect args}" end
    GenServer.start_link(__MODULE__, args)
  end

  @doc """
  Notify the DHCP server to release the IP address currently assigned to
  this interface. After calling this, be sure to disassociate the IP address
  from the interface so that packets don't accidentally get sent or processed.
  """
  def release(pid) do
    GenServer.call(pid, :release)
  end

  @doc """
  Renew the lease on the IP address with the DHCP server.
  """
  def renew(pid) do
    GenServer.call(pid, :renew)
  end

  @doc """
  Stop the dhcp client
  """
  def stop(pid) do
    Logger.debug fn -> "Dhclient.stop ipid: #{inspect pid}" end
    GenServer.stop(pid)
  end

  defp dhclient_mode_args(:stateful) do
    []
  end

  defp dhclient_mode_args(:stateless) do
    ["-S"]
  end

  defp runtime_lease_file(runtime) do
      if Keyword.has_key?(runtime, :lease_file) do
        [ "-lf" | Keyword.get_values(runtime, :lease_file) ]
      else
        []
      end
  end

  defp runtime_pid_file(runtime) do
      if Keyword.has_key?(runtime, :pid_file) do
        [ "-pf" | Keyword.get_values(runtime, :pid_file) ]
      else
        []
      end
  end

  # Parsing config.exs entry of the following format: [dhclient: [lease_file: "/var/system/dhclient6.leases", pid_file: "/var/system/dhclient6.pid"]]
  defp dhclient_runtime() do
  
    [ipv6: runtime] = Application.get_env(:nerves_network, :dhclient, [])
     Logger.debug fn -> "#{__MODULE__}: runtime options = #{inspect runtime}" end
     runtime_lease_file(runtime) ++ runtime_pid_file(runtime)
  end

  def init(args) do
    {ifname, mode} = args
    Logger.info fn -> "#{__MODULE__}: Starting Dhclient wrapper for ifname: #{inspect ifname} mode: #{inspect mode}" end

    priv_path = :code.priv_dir(:nerves_network)
    port_path = "#{priv_path}/dhclient_wrapper"

    args = ["dhclient",
            "-6", #IPv6 
            "-sf", port_path, #The script to be invoked at the lease time
            "-d"] #force to run in foreground
            ++ dhclient_mode_args(mode)
            ++ dhclient_runtime()
            ++ [ifname]

    port = Port.open({:spawn_executable, port_path},
                     [{:args, args}, :exit_status, :stderr_to_stdout, {:line, 256}])

    Logger.info fn -> "#{__MODULE__}: Dhclient port: #{inspect  port}; args: #{inspect args}" end

    {:ok, %{ifname: ifname, port: port}}
  end

  def terminate(_reason, state) do
    # Send the command to our wrapper to shut everything down.
    Logger.debug fn -> "#{__MODULE__}: terminate..." end
    Port.command(state.port, <<@terminate>>);
    Port.close(state.port)
    :ok
  end

  def handle_call(:renew, _from, state) do
    # If we send a byte with the value 1 to the wrapper, it will turn it into
    # a SIGUSR1 for dhclient so that it renews the IP address.
    Port.command(state.port, <<@renew>>);
    {:reply, :ok, state}
  end

  def handle_call(:release, _from, state) do
    Port.command(state.port, <<@release>>);
    {:reply, :ok, state}
  end

  # def handle_cast(:stop, state) do
  #   {:stop, :normal, state}
  # end

  def handle_info({_, {:data, {:eol, message}}}, state) do
    message
      |> List.to_string
      |> String.split(",")
      |> handle_dhclient(state)
  end

  defp handle_dhclient(["deconfig", ifname | _rest], state) do
    Logger.debug "dhclient: deconfigure #{ifname}"

    Utils.notify(Nerves.Dhclient, state.ifname, :deconfig, %{ifname: ifname})
    {:noreply, state}
  end
  defp handle_dhclient(["bound", ifname, ip, broadcast, subnet, router, domain, dns, _message], state) do
    dnslist = String.split(dns, " ")
    Logger.debug "dhclient: bound #{ifname}: IP=#{ip}, dns=#{inspect dns}"
    Utils.notify(Nerves.Dhclient, state.ifname, :bound, %{ifname: ifname, ipv4_address: ip, ipv4_broadcast: broadcast, ipv4_subnet_mask: subnet, ipv4_gateway: router, domain: domain, nameservers: dnslist})
    {:noreply, state}
  end
  defp handle_dhclient(["renew", ifname, ip, broadcast, subnet, router, domain, dns, _message], state) do
    dnslist = String.split(dns, " ")
    Logger.debug "dhclient: renew #{ifname}"
    Utils.notify(Nerves.Dhclient, state.ifname, :renew, %{ifname: ifname, ipv4_address: ip, ipv4_broadcast: broadcast, ipv4_subnet_mask: subnet, ipv4_gateway: router, domain: domain, nameservers: dnslist})
    {:noreply, state}
  end
  defp handle_dhclient(["leasefail", ifname, _ip, _broadcast, _subnet, _router, _domain, _dns, message], state) do
    Logger.debug "dhclient: #{ifname}: leasefail #{message}"
    Utils.notify(Nerves.Dhclient, state.ifname, :leasefail, %{ifname: ifname, message: message})
    {:noreply, state}
  end
  defp handle_dhclient(["nak", ifname, _ip, _broadcast, _subnet, _router, _domain, _dns, message], state) do
    Logger.debug "dhclient: #{ifname}: NAK #{message}"
    Utils.notify(Nerves.Dhclient, state.ifname, :nak, %{ifname: ifname, message: message})
    {:noreply, state}
  end
  defp handle_dhclient(_something_else, state) do
    #msg = List.foldl(something_else, "", &<>/2)
    #Logger.debug "dhclient: ignoring unhandled message: #{msg}"
    {:noreply, state}
  end
end
