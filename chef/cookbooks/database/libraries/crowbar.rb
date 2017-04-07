module CrowbarDatabaseHelper
  def self.get_ha_vhostname(node)
    if node[:database][:ha][:enabled]
      # Any change in the generation of the vhostname here must be reflected in
      # apply_role_pre_chef_call of the database barclamp model
      "#{node[:database][:config][:environment].gsub("-config", "")}-#{CrowbarPacemakerHelper.cluster_name(node)}".gsub("_", "-")
    else
      nil
    end
  end

  def self.get_config_listen_addresses(node)
    node_addr = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
    if node[:database][:ha][:enabled]
      vhostname = get_ha_vhostname(node)
      vip_addr = CrowbarPacemakerHelper.cluster_vip(node, "admin", vhostname)
      if node[:postgresql][:streaming_replication]
        [vip_addr, node_addr]
      else
        [vip_addr]
      end
    else
      [node_addr]
    end
  end

  def self.get_listen_address(node)
    if node[:database][:ha][:enabled]
      vhostname = get_ha_vhostname(node)
      CrowbarPacemakerHelper.cluster_vip(node, "admin", vhostname)
    else
      Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
    end
  end
end
