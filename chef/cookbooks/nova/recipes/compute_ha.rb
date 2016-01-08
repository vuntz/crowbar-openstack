# Copyright 2016 SUSE
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

remote_nodes = CrowbarPacemakerHelper.remote_nodes(node)
return if remote_nodes.empty?

nova = remote_nodes.first
unless nova.roles.any? { |role| /^nova-compute-/ =~ role }
  raise "Remote nodes don't have a nova compute role!"
end

unless nova[:nova][:ha][:compute][:enabled]
  raise "HA for compute nodes is not enabled!"
end

keystone_settings = KeystoneHelper.keystone_settings(nova, @cookbook_name)
neutrons = search(:node, "roles:neutron-server AND roles:neutron-config-#{nova[:nova][:neutron_instance]}")
neutron = neutrons.first || raise("Neutron instance '#{nova[:nova][:neutron_instance]}' for nova not found")

# Wait for all nodes to reach this point so we know that all nodes will have
# all the required packages installed before we create the pacemaker
# resources
crowbar_pacemaker_sync_mark "sync-nova_compute_before_ha"

# Avoid races when creating pacemaker resources
crowbar_pacemaker_sync_mark "wait-nova_compute_ha_resources"

compute_primitives = []
compute_transaction_objects = []

libvirtd_primitive = "libvirtd-compute"
pacemaker_primitive libvirtd_primitive do
  agent "systemd:libvirtd"
  op nova[:nova][:ha][:op]
  action :update
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end
compute_primitives << libvirtd_primitive
compute_transaction_objects << "pacemaker_primitive[#{libvirtd_primitive}]"

case neutron[:neutron][:networking_plugin]
when "ml2"
  ml2_mech_drivers = neutron[:neutron][:ml2_mechanism_drivers]
  case
  when ml2_mech_drivers.include?("openvswitch")
    neutron_agent = neutron[:neutron][:platform][:ovs_agent_name]
    neutron_agent_ra = neutron[:neutron][:ha][:network]["openvswitch_ra"]
  when ml2_mech_drivers.include?("linuxbridge")
    neutron_agent = neutron[:neutron][:platform][:lb_agent_name]
    neutron_agent_ra = neutron[:neutron][:ha][:network]["linuxbridge_ra"]
  end

  neutron_agent_primitive = "#{neutron_agent.sub(/^openstack-/, "")}-compute"
  pacemaker_primitive neutron_agent_primitive do
    agent neutron_agent_ra
    op neutron[:neutron][:ha][:network][:op]
    action :update
    only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
  end
  compute_primitives << neutron_agent_primitive
  compute_transaction_objects << "pacemaker_primitive[#{neutron_agent_primitive}]"
end

if neutron[:neutron][:use_dvr]
  l3_agent_primitive = "neutron-l3-agent-compute"
  pacemaker_primitive l3_agent_primitive do
    agent neutron[:neutron][:ha][:network][:l3_ra]
    op neutron[:neutron][:ha][:network][:op]
    action :update
    only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
  end
  compute_primitives << l3_agent_primitive
  compute_transaction_objects << "pacemaker_primitive[#{l3_agent_primitive}]"

  metadata_agent_primitive = "neutron-metadata-agent-compute"
  pacemaker_primitive metadata_agent_primitive do
    agent neutron[:neutron][:ha][:network][:metadata_ra]
    op neutron[:neutron][:ha][:network][:op]
    action :update
    only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
  end
  compute_primitives << metadata_agent_primitive
  compute_transaction_objects << "pacemaker_primitive[#{metadata_agent_primitive}]"
end

nova_primitive = "nova-compute"
pacemaker_primitive nova_primitive do
  agent "ocf:openstack:NovaCompute"
  params ({
    "auth_url"       => keystone_settings["internal_auth_url"],
    # "region_name"    => keystone_settings["endpoint_region"],
    "endpoint_type"  => "internalURL",
    "username"       => keystone_settings["admin_user"],
    "password"       => keystone_settings["admin_password"],
    "tenant_name"    => keystone_settings["admin_tenant"],
    # "insecure"       => keystone_settings["insecure"] || nova[:nova][:ssl][:insecure],
    "domain"         => node[:domain]
  })
  op nova[:nova][:ha][:compute][:compute][:op]
  action :update
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end
compute_primitives << nova_primitive
compute_transaction_objects << "pacemaker_primitive[#{nova_primitive}]"

compute_group_name = "g-#{nova_primitive}"
pacemaker_group compute_group_name do
  members compute_primitives
  action :update
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end
compute_transaction_objects << "pacemaker_group[#{compute_group_name}]"

compute_clone_name = "cl-#{compute_group_name}"
pacemaker_clone compute_clone_name do
  rsc compute_group_name
  meta ({ "clone-max" => CrowbarPacemakerHelper.num_remote_nodes(node) })
  action :update
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end
compute_transaction_objects << "pacemaker_clone[#{compute_clone_name}]"

compute_location_name = "l-#{compute_clone_name}-compute"
pacemaker_location compute_location_name do
  definition OpenStackHAHelper.compute_only_location(compute_location_name, compute_clone_name)
  action :update
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end
compute_transaction_objects << "pacemaker_location[#{compute_location_name}]"

pacemaker_transaction "nova compute" do
  cib_objects compute_transaction_objects
  # note that this will also automatically start the resources
  action :commit_new
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end

controller_transaction_objects = []

evacuate_primitive = "nova-evacuate"
pacemaker_primitive evacuate_primitive do
  agent "ocf:openstack:NovaEvacuate"
  params ({
    "auth_url"       => keystone_settings["internal_auth_url"],
    # "region_name"    => keystone_settings["endpoint_region"],
    "endpoint_type"  => "internalURL",
    "username"       => keystone_settings["admin_user"],
    "password"       => keystone_settings["admin_password"],
    "tenant_name"    => keystone_settings["admin_tenant"]
    # "insecure"       => keystone_settings["insecure"] || nova[:nova][:ssl][:insecure]
  })
  op nova[:nova][:ha][:compute][:evacuate][:op]
  action :update
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end
controller_transaction_objects << "pacemaker_primitive[#{evacuate_primitive}]"

controller_location_name = "l-#{evacuate_primitive}-controller"
pacemaker_location controller_location_name do
  definition OpenStackHAHelper.controller_only_location(controller_location_name, evacuate_primitive)
  action :update
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end
controller_transaction_objects << "pacemaker_location[#{controller_location_name}]"

order_name = "o-#{compute_clone_name}"
pacemaker_order order_name do
  score "Mandatory"
  ordering "#{compute_clone_name} #{evacuate_primitive}"
  action :update
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end
controller_transaction_objects << "pacemaker_order[#{order_name}]"

fence_primitive = "fence-nova"
pacemaker_primitive fence_primitive do
  agent "stonith:fence_compute"
  params ({
    "auth-url"       => keystone_settings["internal_auth_url"],
    # "region-name"    => keystone_settings["endpoint_region"],
    "endpoint-type"  => "internalURL",
    "login"          => keystone_settings["admin_user"],
    "passwd"         => keystone_settings["admin_password"],
    "tenant-name"    => keystone_settings["admin_tenant"],
    # "insecure"       => keystone_settings["insecure"] || nova[:nova][:ssl][:insecure],
    "domain"         => node[:domain],
    "record-only"    => "1",
    "verbose"        => "1",
    "debug"          => "/var/log/nova/fence_compute.log"
  })
  op nova[:nova][:ha][:compute][:fence][:op]
  action :update
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end
controller_transaction_objects << "pacemaker_primitive[#{fence_primitive}]"

pacemaker_transaction "nova compute (non-remote bits)" do
  cib_objects controller_transaction_objects
  # note that this will also automatically start the resources
  action :commit_new
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end

unless %w(disabled manual).include? node[:pacemaker][:stonith][:mode]
  case node[:pacemaker][:stonith][:mode]
  when "sbd"
    stonith_resource = "stonith-sbd"
  when "shared"
    stonith_resource = "stonith-shared"
  when "per_node"
    stonith_resource = nil
  else
    raise "Unknown STONITH mode: #{node[:pacemaker][:stonith][:mode]}."
  end

  topology = remote_nodes.map do |remote_node|
    remote_stonith = stonith_resource
    remote_stonith ||= "stonith-remote-#{remote_node[:hostname]}"
    "remote-#{remote_node[:hostname]}: #{remote_stonith},#{fence_primitive}"
  end

  # TODO: implement proper LWRP for this, and move this as part of the
  # transaction for controller bits
  bash "crm configure fencing_topology" do
    code "echo fencing_topology #{topology.join(" ")} | crm configure load update -"
  end
end

crowbar_pacemaker_order_only_existing "o-#{evacuate_primitive}" do
# TODO: pretty sure we shouldn't have all of these in the order
  ordering "( postgresql rabbitmq cl-keystone cl-g-glance cl-g-cinder-controller cl-neutron-server cl-g-neutron-agents cl-g-nova-controller ) #{evacuate_primitive}"
  score "Mandatory"
  action :create
  only_if { CrowbarPacemakerHelper.is_cluster_founder?(node) }
end

crowbar_pacemaker_sync_mark "create-nova_compute_ha_resources"