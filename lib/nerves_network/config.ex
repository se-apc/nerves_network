defmodule Nerves.Network.Config  do
  @moduledoc false

  use GenServer

  require Logger

  alias SystemRegistry, as: SR
  alias Nerves.Network.{IFSupervisor, Types}

  @scope [:config, :network_interface]
  @priority :nerves_network

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec put(Types.ifname, Nerves.Network.setup_settings, atom) :: {:ok, {old :: map, new ::map}}
  def put(iface, config, priority \\ @priority) do
    scope(iface)
    |> SR.update(config, [priority: priority])
  end

  @spec drop(Types.ifname, atom) :: {:ok, {old :: map, new ::map}}
  def drop(iface, priority \\ @priority) do
    Nerves.Network.IFSupervisor.teardown(iface)

    scope(iface)
    |> SR.delete(priority: priority)
  end

  def init([]) do
    Logger.debug("initialising... args= []")
    # If we enable hysteresis we will drop updates that
    # are needed to setup ipv4 and ipv6
    SR.register(min_interval: 500)
    defaults =
      Application.get_env(:nerves_network, :default, [])

    Logger.debug("defaults = #{inspect defaults}")

    Process.send_after(self(), {:setup_default_ifaces, defaults}, 0)
    {:ok, %{}}
  end

  def handle_info({:setup_default_ifaces, defaults}, state) do
    Enum.each(defaults, fn({iface, config}) ->
      scope(iface)
         |> SR.update(config, priority: :default)
    end)
    {:noreply, state}
  end

  def handle_info({:system_registry, :global, registry}, s) do
    # The registry is HUGE.  Do not inspect unless its necessary
    net_config = get_in(registry, @scope) || %{}
    s = update(net_config, s)
    {:noreply, s}
  end

  def update(old, old, _) do
    Logger.debug("update old**2 = #{inspect old}")
    {old, []}
  end

  def update(new, old) do
    Logger.debug("update new = #{inspect new}")
    Logger.debug("update old = #{inspect old}")
    {added, removed, modified} =
      changes(new, old)

    removed = Enum.map(removed, fn({k, _}) -> {k, %{}} end)
    modified = added ++ modified

    Enum.each(modified, fn({iface, settings}) ->
      IFSupervisor.setup(iface, settings)
    end)

    Logger.debug("removed = #{inspect removed}")

    Enum.each(removed, fn({iface, _settings}) ->
      IFSupervisor.teardown(iface)
    end)
    new
  end

  @spec scope(Types.ifname, append :: SR.scope) :: SR.scope
  defp scope(iface, append \\ []) do
    @scope ++ [iface | append]
  end

  defp changes(new, old) do
    Logger.debug("changes new = #{inspect new}")
    Logger.debug("changes old = #{inspect old}")

    added =
      Enum.filter(new, fn({k, _}) -> Map.get(old, k) == nil end)
    removed =
      Enum.filter(old, fn({k, _}) -> Map.get(new, k) == nil end)
    modified =
      Enum.filter(new, fn({k, v}) ->
        val = Map.get(old, k)
        val != nil and val != v
      end)
    {added, removed, modified}
  end
end
