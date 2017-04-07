#
# Cookbook Name:: postgresql
# Recipe:: server
#
# Author:: Joshua Timberman (<joshua@opscode.com>)
# Author:: Lamont Granquist (<lamont@opscode.com>)#
# Copyright 2009-2011, Opscode, Inc.
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

include_recipe "postgresql::client"

node["postgresql"]["server"]["packages"].each do |pg_pack|
  package pg_pack
end

ha_enabled = node[:database][:ha][:enabled]
streaming_replication_enabled = ha_enabled && node[:postgresql][:streaming_replication]

# We need to include the HA recipe early, before the config files are
# generated, but after the postgresql packages are installed since they live in
# the directory that will be mounted for HA
if ha_enabled && !streaming_replication_enabled
  include_recipe "postgresql::ha_storage"
end

service "postgresql" do
  service_name node["postgresql"]["server"]["service_name"]
  supports restart: true, status: true, reload: true
  action [:enable, :start]
  provider Chef::Provider::CrowbarPacemakerService if node[:database][:ha][:enabled]
end
