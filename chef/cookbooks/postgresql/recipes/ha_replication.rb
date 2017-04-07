# Copyright 2017 SUSE
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

vip_addr = CrowbarDatabaseHelper.get_listen_address(node)

###
### First start with the setup of streaming replication
###

replica_user = node["postgresql"]["replica_user"]
replica_password = node["postgresql"]["replica_password"]

template "#{node["postgresql"]["dir"]}/recovery.conf.pcmk" do
  source "recovery.conf.pcmk.erb"
  owner "postgres"
  group "postgres"
  mode 0600
  variables(
    master_vip: vip_addr,
    port: node["postgresql"]["config"]["port"],
    replica_user: replica_user,
    replica_password: replica_password
  )
end

# Non-founder nodes should not start streaming replication setup until we're
# ready on the founder
crowbar_pacemaker_sync_mark "wait-database_streaming_replication_setup" do
  revision node[:database]["crowbar-revision"]
end

service "postgresql start for streaming replication setup" do
  service_name node["postgresql"]["server"]["service_name"]
  action :start
  not_if { node[:postgresql][:streaming_replication_setup] }
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end

# keep in sync with resource in server.rb
bash "create replication user for streaming replication" do
  user "postgres"
  code <<-EOH
    echo "SELECT rolname FROM pg_roles WHERE rolname='#{replica_user}';" | psql | grep -q #{replica_user}
    if [ $? -ne 0 ]; then
        echo "CREATE ROLE #{replica_user} WITH LOGIN REPLICATION ENCRYPTED PASSWORD '#{replica_password}';" | psql
    else
        echo "ALTER ROLE #{replica_user} ENCRYPTED PASSWORD '#{replica_password}';" | psql
    fi
EOH
  action :run
  not_if { node[:postgresql][:streaming_replication_setup] }
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end

founder = CrowbarPacemakerHelper.cluster_founder(node)
founder_ip_addr = Barclamp::Inventory.get_network_by_type(founder, "admin").address
founder_port = founder["postgresql"]["config"]["port"]
# parent dir of the pg data dir is usually the home of the postgres user, so
# good fit for hosting a pgpass file
pgpassfile = "#{File.dirname(node["postgresql"]["dir"])}/.pgpass.streaming_replication_setup"

file "create pgpass file for streaming replication setup" do
  path pgpassfile
  content "#{founder_ip_addr}:#{founder_port}:*:#{replica_user}:#{replica_password}"
  owner "postgres"
  group "postgres"
  mode 0600
  not_if { node[:postgresql][:streaming_replication_setup] }
  not_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end

bash "initial streaming replication setup on slave nodes" do
  user "postgres"
  code <<-EOH
    rm -rf #{node["postgresql"]["dir"]}
    pg_basebackup --xlog-method=stream --pgdata=#{node["postgresql"]["dir"]} -U #{replica_user} -h #{founder_ip_addr} -p #{founder_port} --no-password
    cp #{node["postgresql"]["dir"]}/recovery.conf.pcmk #{node["postgresql"]["dir"]}/recovery.conf
EOH
  environment ({
    "PGPASSFILE" => pgpassfile
  })
  action :run
  not_if { node[:postgresql][:streaming_replication_setup] }
  not_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end

file "delete pgpass file for streaming replication setup" do
  path pgpassfile
  action :delete
  not_if { node[:postgresql][:streaming_replication_setup] }
  not_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end

ruby_block "restore config after streaming replication setup on slave nodes" do
  block do
    [
      "#{node['postgresql']['dir']}/postgresql.conf",
      "#{node['postgresql']['dir']}/pg_hba.conf",
      "#{node["postgresql"]["dir"]}/recovery.conf.pcmk"
    ].each do |file|
      resource = resources(template: file)
      resource.run_action(:create)
    end
  end
  action :create
  not_if { node[:postgresql][:streaming_replication_setup] }
  not_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end

crowbar_pacemaker_sync_mark "create-database_streaming_replication_setup" do
  revision node[:database]["crowbar-revision"]
end

# Wait for all nodes to be there (== being done with streaming replication
# setup) before stopping postgresql on founder
crowbar_pacemaker_sync_mark "sync-database_streaming_replication_setup" do
  revision node[:database]["crowbar-revision"]
end

service "postgresql stop for streaming replication setup" do
  service_name node["postgresql"]["server"]["service_name"]
  action :stop
  not_if { node[:postgresql][:streaming_replication_setup] }
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end

ruby_block "mark node for completion of streaming replication setup" do
  block do
    node.set[:postgresql][:streaming_replication_setup] = true
    node.save
  end
  action :create
  not_if { node[:postgresql][:streaming_replication_setup] }
end

###
### Now the pacemaker bits
###

package "resource-agents-paf"

# Wait for all "database" nodes to reach this point so we know that
# they will have all the required packages installed and configuration
# files updated before we create the pacemaker resources.
crowbar_pacemaker_sync_mark "sync-database_before_ha" do
  revision node[:database]["crowbar-revision"]
end

# Avoid races when creating pacemaker resources
crowbar_pacemaker_sync_mark "wait-database_ha_resources" do
  revision node[:database]["crowbar-revision"]
end

transaction_objects = []

vip_op = {}
vip_op["monitor"] = {}
vip_op["monitor"]["interval"] = "10s"

vip_primitive = "vip-admin-#{CrowbarDatabaseHelper.get_ha_vhostname(node)}"
pacemaker_primitive vip_primitive do
  agent "ocf:heartbeat:IPaddr2"
  params ({
    "ip" => vip_addr
  })
  op vip_op
  action :update
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end
transaction_objects.push("pacemaker_primitive[#{vip_primitive}]")

vip_location_name = openstack_pacemaker_controller_only_location_for vip_primitive
transaction_objects.push("pacemaker_location[#{vip_location_name}]")

agent_name = "ocf:heartbeat:pgsqlms"
# these come from the PAF documentation
postgres_op = {
  # note: we don't want to use symbols here, as the pacemaker cookbook doesn't
  # support that
  "start" => { "timeout" => "60s" },
  "stop" => { "timeout" => "60s" },
  "promote" => { "timeout" => "30s" },
  "demote" => { "timeout" => "120s" },
  # TODO: should be different for master & slave
  "monitor" => { "interval" => "15s", "timeout" => "10s" },
  "notify" => { "timeout" => "60s" }
}

service_name = "postgresql"
pacemaker_primitive service_name do
  agent agent_name
  params ({
    "pgdata" => node["postgresql"]["dir"],
    "pghost" => vip_addr,
    "pgport" => node["postgresql"]["config"]["port"]
  })
  op postgres_op
  action :update
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end
transaction_objects.push("pacemaker_primitive[#{service_name}]")

# no location on the role here: the ms resource will have this constraint

ms_name = "ms-#{service_name}"
pacemaker_ms ms_name do
  rsc service_name
  meta ({
    "master-max" => "1",
    "master-node-max" => "1",
    "ordered" => "false",
    "interleave" => "false",
    "notify" => "true"
  })
  action :update
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end
transaction_objects.push("pacemaker_ms[#{ms_name}]")

ms_location_name = openstack_pacemaker_controller_only_location_for ms_name
transaction_objects.push("pacemaker_location[#{ms_location_name}]")

colocation_constraint = "col-#{ms_name}"
pacemaker_colocation colocation_constraint do
  score "inf"
  resources "#{vip_primitive} #{ms_name}:Master"
  action :update
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end
transaction_objects.push("pacemaker_colocation[#{colocation_constraint}]")

order_promote_constraint = "o-promote-#{ms_name}"
pacemaker_order order_promote_constraint do
  score "Mandatory"
  #TODO: "symmetrical=false" like this is ugly
  ordering "#{ms_name}:promote #{vip_primitive}:start symmetrical=false"
  action :update
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end
transaction_objects.push("pacemaker_order[#{order_promote_constraint}]")

order_demote_constraint = "o-demote-#{ms_name}"
pacemaker_order order_demote_constraint do
  score "Mandatory"
  #TODO: "symmetrical=false" like this is ugly
  ordering "#{ms_name}:demote #{vip_primitive}:stop symmetrical=false"
  action :update
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end
transaction_objects.push("pacemaker_order[#{order_demote_constraint}]")

pacemaker_transaction "database service" do
  cib_objects transaction_objects
  # note that this will also automatically start the resources
  action :commit_new
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end

crowbar_pacemaker_sync_mark "create-database_ha_resources" do
  revision node[:database]["crowbar-revision"]
end

# wait for service to have a master, and to be active
ruby_block "wait for #{ms_name} to be started" do
  block do
    require "timeout"
    begin
      Timeout.timeout(30) do
        ::Kernel.system("crm_resource --wait --resource #{ms_name}")
        cmd = "su - postgres -c 'psql -c \"select now();\"' &> /dev/null"
        while ! ::Kernel.system(cmd)
          Chef::Log.debug("#{service_name} still not answering")
          sleep(2)
        end
      end
    rescue Timeout::Error
      message = "PostgreSQL is not started. Please manually check for an error."
      Chef::Log.fatal(message)
      raise message
    end
  end # block
end # ruby_block
