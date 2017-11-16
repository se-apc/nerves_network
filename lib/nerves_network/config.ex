defmodule Nerves.Network.Config  do
  use GenServer

  require Logger

  alias SystemRegistry, as: SR
  alias Nerves.Network.IFSupervisor

  @scope [:config, :network_interface]
  @priority :nerves_network

  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def put(iface, config, priority \\ @priority) do
    scope(iface)
    |> SR.update(config, priority: priority)
  end

  def drop(iface, priority \\ @priority) do
    scope(iface)
    |> SR.delete(priority: priority)
  end

  def init([]) do
    SR.register
    defaults =
      Application.get_env(:nerves_network, :default, [])
    Enum.each(defaults, fn({iface, config}) ->
      iface
      |> to_string()
      |> put(config, :default)
    end)
    {:ok, %{}}
  end

  def handle_info({:system_registry, :global, registry}, s) do
    net_config = get_in(registry, @scope) || %{}
    s = update(net_config, s)
    {:noreply, s}
  end

  def update(old, old, _) do
    {old, []}
  end

  def update(new, old) do
    Logger.debug fn -> "#{__MODULE__}: update new = #{inspect new}" end
    Logger.debug fn -> "#{__MODULE__}: update old = #{inspect old}" end
    {added, removed, modified} =
      changes(new, old)

    removed = Enum.map(removed, fn({k, _}) -> {k, %{}} end)
    modified = added ++ modified

    Logger.debug fn -> "#{__MODULE__}: modified = #{inspect modified}" end
    Enum.each(modified, fn({iface, settings}) ->
      IFSupervisor.setup(iface, settings)
    end)

    Logger.debug fn -> "#{__MODULE__}: removed = #{inspect removed}" end
    Enum.each(removed, fn({iface, _settings}) ->
      IFSupervisor.teardown(iface)
    end)
    new
  end

  defp scope(iface, append \\ []) do
    @scope ++ [iface | append]
  end

  defp changes(new, old) do
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
