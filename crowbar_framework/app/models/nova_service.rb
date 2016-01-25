#
# Copyright 2011-2013, Dell
# Copyright 2013-2014, SUSE LINUX Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

class NovaService < PacemakerServiceObject
  def initialize(thelogger)
    super(thelogger)
    @bc_name = "nova"
  end

# Turn off multi proposal support till it really works and people ask for it.
  def self.allow_multiple_proposals?
    false
  end

  class << self
    def role_constraints
      {
        "nova-controller" => {
          "unique" => false,
          "count" => 1,
          "exclude_platform" => {
            "suse" => "< 12.1",
            "windows" => "/.*/"
          },
          "cluster" => true
        },
        "nova-compute-docker" => {
          "unique" => false,
          "count" => -1,
          "exclude_platform" => {
            "suse" => "< 12.1",
            "windows" => "/.*/"
          }
        },
        "nova-compute-hyperv" => {
          "unique" => false,
          "count" => -1,
          "platform" => {
            "windows" => "/.*/"
          }
        },
        "nova-compute-kvm" => {
          "unique" => false,
          "count" => -1,
          "exclude_platform" => {
            "suse" => "< 12.1",
            "windows" => "/.*/"
          }
        },
        "nova-compute-qemu" => {
          "unique" => false,
          "count" => -1,
          "exclude_platform" => {
            "suse" => "< 12.1",
            "windows" => "/.*/"
          }
        },
        "nova-compute-vmware" => {
          "unique" => false,
          "count" => 1,
          "exclude_platform" => {
            "suse" => "< 12.1",
            "windows" => "/.*/"
          }
        },
        "nova-compute-zvm" => {
          "unique" => false,
          "count" => 1,
          "exclude_platform" => {
            "suse" => "< 12.1",
            "windows" => "/.*/"
          }
        },
        "nova-compute-xen" => {
          "unique" => false,
          "count" => -1,
          "platform" => {
            "suse" => "12.1",
          }
        }
      }
    end
  end

  def proposal_dependencies(role)
    answer = []
    answer << { "barclamp" => "database", "inst" => role.default_attributes["nova"]["database_instance"] }
    answer << { "barclamp" => "keystone", "inst" => role.default_attributes["nova"]["keystone_instance"] }
    answer << { "barclamp" => "glance", "inst" => role.default_attributes["nova"]["glance_instance"] }
    answer << { "barclamp" => "rabbitmq", "inst" => role.default_attributes["nova"]["rabbitmq_instance"] }
    answer << { "barclamp" => "cinder", "inst" => role.default_attributes[@bc_name]["cinder_instance"] }
    answer << { "barclamp" => "neutron", "inst" => role.default_attributes[@bc_name]["neutron_instance"] }
    answer
  end

  def node_supports_xen(node)
    return false if node[:platform_family] != "suse"
    return false if node[:block_device].include?("vda")
    node["kernel"]["machine"] =~ /x86_64/
  end

  def node_supports_kvm(node)
    return false if node[:cpu].nil? || node[:cpu]["0"].nil? || node[:cpu]["0"][:flags].nil?
    node[:cpu]["0"][:flags].include?("vmx") or node[:cpu]["0"][:flags].include?("svm")
  end

  #
  # Lots of enhancements here.  Like:
  #    * Don't reuse machines
  #    * validate hardware.
  #
  def create_proposal
    @logger.debug("Nova create_proposal: entering")
    base = super
    @logger.debug("Nova create_proposal: done with base")

    nodes = NodeObject.all
    nodes.delete_if { |n| n.nil? }
    nodes.delete_if { |n| n.admin? } if nodes.size > 1
    nodes.delete_if { |n| n.intended_role == "storage" }

    controller  = nodes.delete nodes.detect { |n| n if n.intended_role == "controller" }
    controller ||= nodes.shift
    nodes = [controller] if nodes.empty?

    # restrict nodes to 'compute' roles only if compute role was defined
    if nodes.detect { |n| n if n.intended_role == "compute" }
      nodes       = nodes.select { |n| n if n.intended_role == "compute" }
    end

    hyperv = nodes.select { |n| n if n[:target_platform] =~ /^(windows-|hyperv-)/ }
    non_hyperv = nodes - hyperv
    kvm = non_hyperv.select { |n| n if node_supports_kvm(n) }
    non_kvm = non_hyperv - kvm
    xen = non_kvm.select { |n| n if node_supports_xen(n) }
    qemu = non_kvm - xen

    # do not use docker by default
    # do not use zvm by default
    #   TODO add it here once a compute node can run inside z/VM
    base["deployment"]["nova"]["elements"] = {
      "nova-controller" => [controller.name],
      "nova-compute-hyperv" => hyperv.map(&:name),
      "nova-compute-kvm" => kvm.map(&:name),
      "nova-compute-qemu" => qemu.map(&:name),
      "nova-compute-xen" => xen.map(&:name)
    }

    base["attributes"][@bc_name]["itxt_instance"] = find_dep_proposal("itxt", true)
    base["attributes"][@bc_name]["database_instance"] = find_dep_proposal("database")
    base["attributes"][@bc_name]["rabbitmq_instance"] = find_dep_proposal("rabbitmq")
    base["attributes"][@bc_name]["keystone_instance"] = find_dep_proposal("keystone")
    base["attributes"][@bc_name]["glance_instance"] = find_dep_proposal("glance")
    base["attributes"][@bc_name]["cinder_instance"] = find_dep_proposal("cinder")
    base["attributes"][@bc_name]["neutron_instance"] = find_dep_proposal("neutron")

    base["attributes"]["nova"]["service_password"] = random_password
    base["attributes"]["nova"]["db"]["password"] = random_password
    base["attributes"]["nova"]["neutron_metadata_proxy_shared_secret"] = random_password

    @logger.debug("Nova create_proposal: exiting")
    base
  end

  def apply_role_pre_chef_call(old_role, role, all_nodes)
    @logger.debug("Nova apply_role_pre_chef_call: entering #{all_nodes.inspect}")
    return if all_nodes.empty?

    unless hyperv_available?
      role.override_attributes["nova"]["elements"]["nova-compute-hyperv"] = []
    end

    controller_elements, controller_nodes, ha_enabled = role_expand_elements(role, "nova-controller")
    reset_sync_marks_on_clusters_founders(controller_elements)
    Openstack::HA.set_controller_role(controller_nodes) if ha_enabled

    vip_networks = ["admin", "public"]

    dirty = false
    dirty = prepare_role_for_ha_with_haproxy(role, ["nova", "ha", "enabled"], ha_enabled, controller_elements, vip_networks)
    role.save if dirty

    net_svc = NetworkService.new @logger
    # All nodes must have a public IP, even if part of a cluster; otherwise
    # the VIP can't be moved to the nodes
    controller_nodes.each do |n|
      net_svc.allocate_ip "default", "public", "host", n
    end

    allocate_virtual_ips_for_any_cluster_in_networks_and_sync_dns(controller_elements, vip_networks)

    neutron = Proposal.where(barclamp: "neutron", name: role.default_attributes["nova"]["neutron_instance"]).first

    compute_nodes_for_network = []
    role.override_attributes["nova"]["elements"].each do |role, nodes|
      # only care about compute nodes
      next unless role =~ /^nova-compute-/
      # vmware compute nodes do not need access to the networking
      next if role == "nova-compute-vmware"

      compute_nodes_for_network << nodes
    end
    compute_nodes_for_network.flatten!

    neutron_service = NeutronService.new @logger

    compute_nodes_for_network.each do |n|
      neutron_service.enable_neutron_networks(neutron["attributes"]["neutron"],
                                              n, net_svc,
                                              neutron["attributes"]["neutron"]["use_dvr"])
    end unless all_nodes.nil?

    @logger.debug("Nova apply_role_pre_chef_call: leaving")
  end

  def apply_role_post_chef_call(old_role, role, all_nodes)
    @logger.debug("Nova apply_role_post_chef_call: entering #{all_nodes.inspect}")

    # !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    # FIXME: we only do it this way because crowbar orchestration is not
    #        good enough at the moment; with proper orchestration, we would
    #        simply trigger a chef-client run on the founder nodes in the core
    #        of crowbar
    # !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    #
    # Look for clusters with remote nodes that are used for compute roles.
    # For each of them:
    #  - assign some nova-compute-ha role to the founder node (by
    #    manipulating run list)
    #  - run chef-client
    # Also look at "remove" roles to remove the nova-compute-ha role
    # from the run list

    compute_ha_role = "nova-compute-ha"
    compute_ha_role_remove = "#{compute_ha_role}_remove"
    role_priority = role.override_attributes["nova"]["element_run_list_order"][compute_ha_role]
    role_state = role.override_attributes["nova"]["element_states"][compute_ha_role]

    founders = []

    # find list of roles which accept clusters with remote nodes
    roles_with_remote = role_constraints.select do |role, constraints|
      constraints["remotes"]
    end.keys

    # now examine all elements in these roles, and look for clusters so we can
    # have a list of founders
    elements = role.override_attributes["nova"]["elements"]
    roles_with_remote.each do |role|
      next unless elements.key? role
      elements[role].each do |element|
        next unless is_remotes? element

        founder = PacemakerServiceObject.cluster_founder(element)
        founders.push(founder) unless founder.nil?
      end
    end

    founders.uniq! { |f| f.name }
    # We cannot detect which cluster with remote nodes got removed (since the
    # _remove roles only track expanded nodes, not clusters); instead, we
    # simply look at the nodes that have the compute-ha role and that shouldn't
    # have it anymore.
    old_founders = NodeObject.find("role:#{compute_ha_role}")
    founders_remove = old_founders - founders

    all_founders = founders + founders_remove

    if all_founders.empty?
      @logger.debug("Nova apply_role_post_chef_call: leaving (no HA orchestration)")
      return
    end

    # Add roles to the run list of the founders
    founders.each do |founder|
      next if founder.role? compute_ha_role

      founder.add_to_run_list(compute_ha_role, role_priority, role_state)
      founder.save
    end

    founders_remove.each do |founder|
      save_it = false
      if founder.role? compute_ha_role
        founder.delete_from_run_list compute_ha_role
        save_it = true
      end
      unless founder.role? compute_ha_role_remove
        founder.add_to_run_list(compute_ha_role_remove, role_priority, role_state)
        save_it = true
      end
      founder.save if save_it
    end

    # Note: there's no need to add nova-config-default role to the founder
    # nodes: they use absolutely nothing from the proposal directly, and
    # instead rely on attributes on the remote nodes.

    all_founders_names = all_founders.map { |f| f.name }

    # run chef-client on all founders in parallel, and wait for all of them
    @logger.debug("AR: Calling chef-client for #{role.name} on founder nodes #{all_founders_names.join(" ")}")

    pids = {}
    all_founders_names.each do |founder|
      filename = "#{ENV['CROWBAR_LOG_DIR']}/chef-client/#{founder}.log"
      pid = run_remote_chef_client(founder, "chef-client", filename)
      pids[pid] = founder
    end

    status = Process.waitall
    badones = status.select { |x| x[1].exitstatus != 0 }
    unless badones.empty?
      message = "Failed to handle remote node delegation on:"
      badones.each do |baddie|
        message = message + " #{pids[baddie[0]]}"
      end
      raise message
    end

    # If chef-client succeeds, then removed founders shouldn't keep the remove
    # role, so delete it from run list
    founders_remove.each do |founder|
      founder.delete_from_run_list compute_ha_role_remove
      founder.save
    end

    @logger.debug("Nova apply_role_post_chef_call: leaving")
  end

  def validate_proposal_after_save proposal
    validate_one_for_role proposal, "nova-controller"

    elements = proposal["deployment"]["nova"]["elements"]
    nodes = Hash.new(0)

    if proposal["attributes"][@bc_name]["use_shared_instance_storage"]
      elements["nova-controller"].each do |element|
        if is_cluster? element
          validation_error I18n.t("barclamp.#{@bc_name}.validation.shared_storage")
          break
        end
      end unless elements["nova-controller"].nil?
    end

    unless elements["nova-compute-hyperv"].empty? || hyperv_available?
      validation_error I18n.t("barclamp.#{@bc_name}.validation.hyperv_support")
    end

    elements["nova-compute-docker"].each do |n|
      nodes[n] += 1
    end unless elements["nova-compute-docker"].nil?
    elements["nova-compute-hyperv"].each do |n|
      nodes[n] += 1
    end unless elements["nova-compute-hyperv"].nil?
    elements["nova-compute-kvm"].each do |n|
      nodes[n] += 1
    end unless elements["nova-compute-kvm"].nil?
    elements["nova-compute-qemu"].each do |n|
      nodes[n] += 1
    end unless elements["nova-compute-qemu"].nil?
    elements["nova-compute-vmware"].each do |n|
      nodes[n] += 1
    end unless elements["nova-compute-vmware"].nil?
    elements["nova-compute-zvm"].each do |n|
      nodes[n] += 1
    end unless elements["nova-compute-zvm"].nil?
    elements["nova-compute-xen"].each do |n|
      nodes[n] += 1

      node = NodeObject.find_node_by_name(n)
      next if node.nil? || node_supports_xen(node)

      node_platform = "#{node[:platform]}-#{node[:platform_version]}"
      validation_error I18n.t(
        "barclamp.#{@bc_name}.validation.xen",
        n: n,
        platform: CrowbarService.pretty_target_platform(node_platform),
        arch: node["kernel"]["machine"]
      )
    end unless elements["nova-compute-xen"].nil?

    nodes.each do |key,value|
      if value > 1
        validation_error I18n.t("barclamp.#{@bc_name}.validation.assigned_node", key: key)
      end
    end unless nodes.nil?

    super
  end

  private

  def hyperv_available?
    return File.exist?("/opt/dell/chef/cookbooks/hyperv")
  end
end
