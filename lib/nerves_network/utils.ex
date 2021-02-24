defmodule Nerves.Network.Utils do
  @moduledoc false
  @scope [:state, :network_interface]

  use Bitwise

  @doc false
  def log_atomized_iface_error(ifname) when is_atom(ifname) do
    require Logger
    Logger.warn "Support for atom interface names is deprecated. Please consider calling as \"#{ifname}\"."
  end


  def notify(registry, key, notif, data) do
    Registry.dispatch(registry, key, fn entries ->
      for {pid, _} <- entries, do: send(pid, {registry, notif, data})
    end)
  end

  def generate_link_local(mac_address) do
    <<x, y, _rest :: bytes>> = :crypto.hash(:md5, mac_address)
    x =
      case x do
        255 -> 254
        0 -> 1
        v -> v
      end
    "169.254.#{x}.#{y}"
  end

  defp bits_set(128), do: 1
  defp bits_set(64),  do: 1
  defp bits_set(32),  do: 1
  defp bits_set(16),  do: 1
  defp bits_set(8),   do: 1
  defp bits_set(4),   do: 1
  defp bits_set(2),   do: 1
  defp bits_set(1),   do: 1
  defp bits_set(0),   do: 0
  defp bits_set(byte) when is_integer(byte) and byte >= 0 and byte <= 255 do
    bits_set(byte &&& 128) +
    bits_set(byte &&& 64) +
    bits_set(byte &&& 32) +
    bits_set(byte &&& 16) +
    bits_set(byte &&& 8) +
    bits_set(byte &&& 4) +
    bits_set(byte &&& 2) +
    bits_set(byte &&& 1)
  end

  @doc """
  Returns `Integer - Prefix length <0..32> used in CIDR notation i.e. 10.1.1.92:24`

  ## Parameters
  - subnet_mask: i.e.: "255.255.255.0"

  ## Examples
  iex> Nerves.Network.Utils.subnet_to_prefix_len("255.255.0.0")
  16

  iex> Nerves.Network.Utils.subnet_to_prefix_len("255.255.255.0")
  24

  iex> Nerves.Network.Utils.subnet_to_prefix_len("255.255.255.128")
  25
  """
  def subnet_to_prefix_len(subnet_mask) do
    String.split(subnet_mask, ".")
    |> Enum.reduce(0, fn byte, acc -> bits_set(String.to_integer(byte)) + acc end)
  end

  def scope(iface, append \\ []) do
    @scope ++ [iface | append]
  end

  @spec is_hex?(String.t()) :: boolean()
  defp is_hex?(octet) do
    try do
      String.to_integer(octet, 16)
      true
    rescue
      _ -> false
    end
  end

  @spec is_two_digit?(String.t()) :: boolean()
  defp is_two_digit?(octet), do: String.length(octet) == 2


  @spec is_two_digit_octet?(String.t()) :: boolean()
  defp is_two_digit_octet?(octet) do
    is_hex?(octet) and is_two_digit?(octet)
  end

  @doc """
  Returns `true | false`.

  ## Parameters
  - mac: MAC address string ':' seprated i.e. "00:00:00:17:12:79"

  ## Examples

        iex> Nerves.Network.Utils.is_mac_eui_48?("00:00:00:17:12:79")
        true

        iex> "00:00:00:17:12" |> Nerves.Network.Utils.is_mac_eui_48?()
        false

        iex> "00:00:00:17:12:gg" |> Nerves.Network.Utils.is_mac_eui_48?()
        false

        iex> "00:00:00:17:12:79:af" |> Nerves.Network.Utils.is_mac_eui_48?()
        false
  """
  @spec is_mac_eui_48?(String.t()) :: boolean()
  def is_mac_eui_48?(mac) do
    split_mac = String.split(mac, ":")
    if Enum.count(split_mac) == 6 do
      Enum.all?(split_mac, fn octet -> is_two_digit_octet?(octet) end)
    else
      false
    end
  end

  @doc """
  Returns `true | false`.

  ## Parameters
  - mac: MAC address string ':' seprated i.e. "03:14:15:92:65:35:89:79"

  ## Examples

        iex> "03:14:15:92:65:35:89:79" |> Nerves.Network.Utils.is_mac_eui_64?()
        true

        iex> "03:14:15:92:65:35" |> Nerves.Network.Utils.is_mac_eui_64?()
        false

        iex> "00:00:00:17:12:gg" |> Nerves.Network.Utils.is_mac_eui_64?()
        false

        iex> "00:00:00:17:12:79:af" |> Nerves.Network.Utils.is_mac_eui_64?()
        false

        iex> "aa:14:15:92:65:35:89:79" |> Nerves.Network.Utils.is_mac_eui_64?()
        true

        iex> "ag:14:15:92:65:35:89:79" |> Nerves.Network.Utils.is_mac_eui_64?()
        false
  """
  @spec is_mac_eui_64?(String.t()) :: boolean()
  def is_mac_eui_64?(mac) do
    split_mac = String.split(mac, ":")
    if Enum.count(split_mac) == 8 do
      Enum.all?(split_mac, fn octet -> is_two_digit_octet?(octet) end)
    else
      false
    end
  end

  defmodule Registry do
    @moduledoc """
    A Registry sumbodule of Nerves.Network.Utils encompassing the utilities associated with the Registry module.
    """

    @type t ::
      {:ok, pid()}
    | {:error, {:already_registered, pid()}}

    @doc """
    Returns `Nerves.Network.Utils.Registry.t()`.

    ## Parameters
    - results: Returned values of of Registry.register/2 function

    ## Examples

    iex> Nerves.Network.Utils.digest_register_results({:ok, pid})
    iex> is_pid(pid) == true

    """
    @spec digest_register_results(t() | any()) :: t() | no_return()
    def digest_register_results(results) do
      case results do
        {:ok, _pid} -> results
        {:error, {:already_registered, _pid}} -> results
        other -> raise "Registry.register(...) returned unexpected results: #{inspect other}!"
      end
    end
  end

end
