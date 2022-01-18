use Mix.Config

key_mgmt = System.get_env("NERVES_NETWORK_KEY_MGMT") || "WPA-PSK"

config :nerves_network, :default,
  wlan0: [
    ssid: System.get_env("NERVES_NETWORK_SSID"),
    psk: System.get_env("NERVES_NETWORK_PSK"),
    key_mgmt: String.to_atom(key_mgmt)
  ],

  #:stateful - Address and other-information i.e. DNSes; The flow is being defined by the DHCPv6 server via A, O, M flags sent in Router Advertisements
  #:stateless - only non-address information
  eth0: [
    ipv4_address_method: :dhcp,
    ipv6_dhcp: :stateful
  ]

#The prefixes for the lease and pid file. The file anmes will be appended with the inetrface's name
#i.e. dhclient6.leases.eth0
config :nerves_network, :dhclientv6,
  ipv6: [
    lease_file:        "/root/dhclient6.leases",
    pid_file:          "/root/dhclient6.pid",
    config_file:       "/root/dhclient6.conf",
    # default_prefix_length: 64,
    flush_resolv_conf: false # At network interface down event clear resolver configuration held in resolv.conf
  ]

config :nerves_network, :dhclientv4,
  ipv4: [
    lease_file:        "/root/dhclient4.leases",
    pid_file:          "/root/dhclient4.pid",
    config_file:       "/root/dhclient4.conf",
    flush_resolv_conf: false # At network interface down event clear resolver configuration held in resolv.conf
  ]

config :nerves_network, :resolver,
  [
    resolvconf_file: "/tmp/resolv.conf"
  ]

config :nerves_network, :eapolmanager,
[
  wpa_supplicant_path:    "/usr/sbin/wpa_supplicant",
  wpa_cli_path:           "/usr/sbin/wpa_cli",
  wpa_control_path:       "/var/run/wpa_supplicant",
  wpa_config_file_prefix: "/var/run/nerves_network_wpa_eapol.conf"
]

