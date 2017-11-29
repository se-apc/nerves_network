defmodule Nerves.Network.Config  do
  use GenServer

  require Logger

  alias SystemRegistry, as: SR
  alias Nerves.Network.IFSupervisor

  use Nerves.Network.Debug

  @scope [:config, :network_interface]
  @priority :nerves_network

  @debug? false

    def start_link do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    end

    def handle_call({:put, iface, config, priority}, _from, state) do
      Logger.debug fn -> "#{__MODULE__}: drop(iface = #{inspect iface}, config = #{inspect config}, priority = #{inspect priority})" end
      result = scope(iface)
               |> SR.update(config, priority: priority)
      {:reply, result, state}
    end

    def handle_call({:drop, iface, priority}, _from, state) do
      Logger.debug fn -> "#{__MODULE__}: drop(iface = #{inspect iface}, priority = #{inspect priority})" end
      result = scope(iface)
               |> SR.delete(priority: priority)
      {:reply, result, state}
     end


    def put(iface, config, priority \\ @priority) do
      GenServer.call(__MODULE__, {:put, iface, config, priority})
    end

    def drop(iface, priority \\ @priority) do
      GenServer.call(__MODULE__, {:drop, iface, priority})
    end


  def init([]) do
    debug_init(@debug?)

    Logger.debug fn -> "#{__MODULE__}: init([])" end

    SR.register
    defaults =
      Application.get_env(:nerves_network, :default, [])

    Logger.debug fn -> "#{__MODULE__}: defaults = #{inspect defaults}" end

    Enum.each(defaults, fn({iface, config}) ->
      iface
      |> to_string()
      |> put(config, :default)
    end)
    {:ok, %{}}
  end

  def handle_info({:system_registry, :global, registry}, s) do
    Logger.debug fn -> "++++ handle_info: registry = #{inspect registry}; s = #{inspect s}" end
    net_config = get_in(registry, @scope) || %{}
    s = update(net_config, s)
    {:noreply, s}
  end

  def update(old, old, _) do
    Logger.debug fn -> "#{__MODULE__}: update old**2 = #{inspect old}" end
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
    Logger.debug fn -> "#{__MODULE__}: changes new = #{inspect new}" end
    Logger.debug fn -> "#{__MODULE__}: changes old = #{inspect old}" end
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
