defmodule Nerves.Network.Debug do
  @moduledoc """
  Module providing debug enabling/disabling functionality.
  """
    defmacro __using__(_) do
        quote([]) do
        #          @behaviour Nerves.Network.Debug

          @doc """
          Returns `:ok`.

          ## Parameters

          ## Examples

                  iex> debug_enable
                  :ok
          """
          def debug_enable do
            Logger.enable(self())
          end

          @doc """
          Returns `:ok`.

          ## Parameters

          ## Examples

                  iex> debug_disable
                  :ok
          """
          def debug_disable do
            Logger.disable(self())
          end

          def debug_init(debug \\ false) do
            unless debug do
              debug_disable()
            end
          end
      end #quote

  end #macro __using__
end
