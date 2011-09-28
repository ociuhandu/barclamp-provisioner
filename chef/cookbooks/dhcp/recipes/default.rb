# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include_recipe "utils"

pkg = ""
case node[:platform]
when "ubuntu","debian"
  pkg = "dhcp3"
  package "dhcp3-server"
when "redhat","centos"
  pkg = "dhcp"
  package "dhcp"
end

directory "/etc/dhcp3"
directory "/etc/dhcp3/groups.d"
directory "/etc/dhcp3/subnets.d"
directory "/etc/dhcp3/hosts.d"

file "/etc/dhcp3/groups.d/group_list.conf" do
  owner "root"
  group "root"
  mode 0644
end
file "/etc/dhcp3/subnets.d/subnet_list.conf" do
  owner "root"
  group "root"
  mode 0644
end
file "/etc/dhcp3/hosts.d/host_list.conf" do
  owner "root"
  group "root"
  mode 0644
end

bash "build omapi key" do
  code <<-EOH
    cd /etc/dhcp3
    dnssec-keygen -r /dev/urandom  -a HMAC-MD5 -b 512 -n HOST omapi_key
    KEY=`cat /etc/dhcp3/Komapi_key*.private|grep ^Key|cut -d ' ' -f2-`
    echo $KEY > /etc/dhcp3/omapi.key
EOH
  not_if "test -f /etc/dhcp3/omapi.key"
end

service "dhcp3-server" do
  service_name "dhcpd" if node[:platform] =~ /^(redhat|centos)$/
  supports :restart => true, :status => true, :reload => true
  action :enable
end

# This needs to be evaled.
intfs = [ Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").interface ]
address = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address

d_opts = node[:dhcp][:options]
d_opts << "next-server #{address}"

case node[:platform]
when "ubuntu","debian"
  template "/etc/dhcp3/dhcpd.conf" do
    owner "root"
    group "root"
    mode 0644
    source "dhcpd.conf.erb"
    variables(:options => d_opts)
    notifies :restart, "service[dhcp3-server]"
  end

  template "/etc/default/dhcp3-server" do
    owner "root"
    group "root"
    mode 0644
    source "dhcp3-server.erb"
    variables(:interfaces => intfs)
    notifies :restart, "service[dhcp3-server]"
  end
when "redhat","centos"
  template "/etc/dhcpd.conf" do
    owner "root"
    group "root"
    mode 0644
    source "dhcpd.conf.erb"
    variables(:options => d_opts)
    notifies :restart, "service[dhcp3-server]"
  end

  template "/etc/sysconfig/dhcpd" do
    owner "root"
    group "root"
    mode 0644
    source "redhat-sysconfig-dhcpd.erb"
    variables(:interfaces => intfs)
    notifies :restart, "service[dhcp3-server]"
  end
end

