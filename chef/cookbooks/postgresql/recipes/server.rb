#
# Cookbook Name:: postgresql
# Recipe:: server
#
# Author:: Joshua Timberman (<joshua@opscode.com>)
# Author:: Lamont Granquist (<lamont@opscode.com>)
# Author:: Ralf Haferkamp (<rhafer@suse.com>)
# Copyright 2009-2011, Opscode, Inc.
# Copyright 2012, SUSE
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

::Chef::Recipe.send(:include, Opscode::OpenSSL::Password)

include_recipe "postgresql::client"

ha_enabled = node[:database][:ha][:enabled]
streaming_replication_enabled = ha_enabled && node[:postgresql][:streaming_replication]

# For Crowbar, we need to set the address to bind - default to admin node.
listen_addresses = CrowbarDatabaseHelper.get_config_listen_addresses(node).join(", ")
if node["postgresql"]["config"]["listen_addresses"] != listen_addresses
  node.set["postgresql"]["config"]["listen_addresses"] = listen_addresses
  node.save
end

# Magic mangling of pg_hba.conf
pg_hba = node["postgresql"]["pg_hba"].dup # we'll possibly change this, so dup it

# migrate pg_hba entry that was hacked in without a marker in old code
pg_hba_internal_entry = pg_hba.find { |x| x[:crowbar_internal] && x[:crowbar_automatic_address] }
if pg_hba_internal_entry.nil? && pg_hba.length == 5 &&
    pg_hba[4][:type] == "host" &&
    pg_hba[4][:db] == "all" &&
    pg_hba[4][:user] == "all" &&
    pg_hba[4][:method] == "md5" &&
    pg_hba[4][:addr] != "127.0.0.1/32" &&
    pg_hba[4][:addr] != "::1/128"
  pg_hba[4][:crowbar_internal] = true
  pg_hba[4][:crowbar_automatic_address] = true
end

newnetaddr = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").subnet
newnetmask = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").netmask
pg_hba_addr = [newnetaddr, newnetmask].join("    ")

pg_hba_internal_entries = pg_hba.select { |x| x[:crowbar_internal] && x[:crowbar_automatic_address] }
# Make sure the network + mask is up-to-date
pg_hba_internal_entries.each do |pg_hba_internal_entry|
  pg_hba_internal_entry[:addr] = pg_hba_addr
end

# Add the network + mask to give access to other nodes in pg_hba.conf if missing
if pg_hba_internal_entries.empty?
  pg_hba.push({
    type: "host",
    db: "all",
    user: "all",
    addr: pg_hba_addr,
    method: "md5",
    crowbar_internal: true,
    crowbar_automatic_address: true
  })
end

if streaming_replication_enabled
  pg_hba_replication_entry = pg_hba.find { |x| x[:crowbar_internal] && x[:db] == "replication" }
  if pg_hba_replication_entry.nil?
    pg_hba.push({
      type: "host",
      db: "replication",
      user: node["postgresql"]["replica_user"],
      addr: pg_hba_addr,
      method: "md5",
      crowbar_internal: true,
      crowbar_automatic_address: true
    })
    # avoid self-replication
    vip_addr = CrowbarDatabaseHelper.get_listen_address(node)
    node_addr = Barclamp::Inventory.get_network_by_type(node, "admin").address
    pg_hba.push({
      type: "host",
      db: "replication",
      user: node["postgresql"]["replica_user"],
      addr: "#{vip_addr}/32",
      method: "reject",
      crowbar_internal: true,
      crowbar_automatic_address: false
    })
    pg_hba.push({
      type: "host",
      db: "replication",
      user: node["postgresql"]["replica_user"],
      addr: "#{node_addr}/32",
      method: "reject",
      crowbar_internal: true,
      crowbar_automatic_address: false
    })
  end
end

if node["postgresql"]["pg_hba"] != pg_hba
  node.set["postgresql"]["pg_hba"] = pg_hba
  node.save
end

# randomly generate postgres password, unless using solo - see README
if Chef::Config[:solo]
  missing_attrs = %w{
    postgres
  }.select do |attr|
    node["postgresql"]["password"][attr].nil?
  end.map { |attr| "node['postgresql']['password']['#{attr}']" }

  if !missing_attrs.empty?
    Chef::Application.fatal!([
        "You must set #{missing_attrs.join(', ')} in chef-solo mode.",
        "For more information, see https://github.com/opscode-cookbooks/postgresql#chef-solo-note"
      ].join(" "))
  end
else
  # TODO: The "secure_password" is randomly generated plain text, so it
  # should be converted to a PostgreSQL specific "encrypted password" if
  # it should actually install a password (as opposed to disable password
  # login for user 'postgres'). However, a random password wouldn't be
  # useful if it weren't saved as clear text in Chef Server for later
  # retrieval.
  node.set_unless["postgresql"]["password"]["postgres"] = secure_password
  node.save
end

# While we would like to include the "postgresql::ha_storage" recipe from here,
# it's not possible: we need to have the packages installed first, and we need
# to include it before we do templates. Which means we need to do it in the
# server_* recipe directly, since they do both.

# Include the right "family" recipe for installing the server
# since they do things slightly differently.
case node[:platform_family]
when "rhel", "fedora", "suse"
  include_recipe "postgresql::server_redhat"
when "debian"
  include_recipe "postgresql::server_debian"
end

change_notify = node["postgresql"]["server"]["config_change_notify"]

template "#{node['postgresql']['dir']}/postgresql.conf" do
  source "postgresql.conf.erb"
  owner "postgres"
  group "postgres"
  mode 0600
  notifies change_notify, "service[postgresql]", :immediately
end

template "#{node['postgresql']['dir']}/pg_hba.conf" do
  source "pg_hba.conf.erb"
  owner "postgres"
  group "postgres"
  mode 00600
  notifies change_notify, "service[postgresql]", :immediately
end

if ha_enabled
  log "HA support for postgresql is enabled"

  if streaming_replication_enabled
    include_recipe "postgresql::ha_replication"
    # Only run the psql commands on the master node
    ms_name = "ms-postgresql"
    only_if_command = "crm resource show #{ms_name} | grep -q \" #{node.hostname} *Master$\""
  else
    include_recipe "postgresql::ha"
    # Only run the psql commands if the service is running on this node, so that
    # we don't depend on the node running the service to be as fast as this one
    service_name = "postgresql"
    only_if_command = "crm resource show #{service_name} | grep -q \" #{node.hostname} *$\""
  end
else
  log "HA support for postgresql is disabled"
end

# NOTE: Consider two facts before modifying "assign-postgres-password":
# (1) Passing the "ALTER ROLE ..." through the psql command only works
#     if passwordless authorization was configured for local connections.
#     For example, if pg_hba.conf has a "local all postgres ident" rule.
# (2) It is probably fruitless to optimize this with a not_if to avoid
#     setting the same password. This chef recipe doesn't have access to
#     the plain text password, and testing the encrypted (md5 digest)
#     version is not straight-forward.
bash "assign-postgres-password" do
  user "postgres"
  code <<-EOH
echo "ALTER ROLE postgres ENCRYPTED PASSWORD '#{node['postgresql']['password']['postgres']}';" | psql -p #{node['postgresql']['config']['port']}
  EOH
  # shouldn't try to update the password on the current 'passive' nodes
  only_if only_if_command if ha_enabled
  action :run
end

# For Crowbar we also need the "db_maker" user
bash "assign-db_maker-password" do
  user "postgres"
  code <<-EOH
    echo "SELECT rolname FROM pg_roles WHERE rolname='db_maker';" | psql | grep -q db_maker
    if [ $? -ne 0 ]; then
        echo "CREATE ROLE db_maker WITH LOGIN CREATEDB CREATEROLE ENCRYPTED PASSWORD '#{node[:database][:db_maker_password]}';" | psql
    else
        echo "ALTER ROLE db_maker ENCRYPTED PASSWORD '#{node[:database][:db_maker_password]}';" | psql
    fi
  EOH
  only_if only_if_command if ha_enabled
  action :run
end

if streaming_replication_enabled
  replica_user = node["postgresql"]["replica_user"]
  replica_password = node["postgresql"]["replica_password"]

  # keep in sync with resource in ha_replication.rb
  bash "assign-replica-password" do
    user "postgres"
    code <<-EOH
      echo "SELECT rolname FROM pg_roles WHERE rolname='#{replica_user}';" | psql | grep -q #{replica_user}
      if [ $? -ne 0 ]; then
          echo "CREATE ROLE #{replica_user} WITH LOGIN REPLICATION ENCRYPTED PASSWORD '#{replica_password}';" | psql
      else
          echo "ALTER ROLE #{replica_user} ENCRYPTED PASSWORD '#{replica_password}';" | psql
      fi
EOH
    only_if only_if_command if ha_enabled
    action :run
  end
end
