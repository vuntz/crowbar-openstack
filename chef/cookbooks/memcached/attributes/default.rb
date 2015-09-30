default[:memcached][:memory] = 64
default[:memcached][:port] = 11211
default[:memcached][:listen] = "0.0.0.0"
default[:memcached][:daemonize] = true

case node[:platform_family]
when "suse"
  default[:memcached][:user] = "memcached"
  default[:memcached][:daemonize] = false if node[:platform_version].to_f >= 12.0 || node[:platform] == "opensuse"
else
  default[:memcached][:user] = "nobody"
end
