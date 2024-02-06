#!/usr/bin/env ruby

require 'json'
require 'mrdialog'
require 'yaml'
require "#{ENV['RBLIB']}/rb_wiz_lib"
require "#{ENV['RBLIB']}/rb_config_utils.rb"

CONFFILE = "#{ENV['RBETC']}/rb_init_conf.yml"
DIALOGRC = "#{ENV['RBETC']}/dialogrc"
if File.exist?(DIALOGRC)
    ENV['DIALOGRC'] = DIALOGRC
end

def cancel_wizard()
    dialog = MRDialog.new
    dialog.clear = true
    dialog.title = "SETUP wizard cancelled"
    text = <<EOF
The setup has been cancelled or stopped.
If you want to complete the setup wizard, please execute it again.
EOF
    result = dialog.msgbox(text, 11, 41)
    exit(1)
end

puts "\033]0;redborder - setup wizard\007"

general_conf = {
    "cloud_address" => "rblive.redborder.com",
    "network" => {
        "interfaces" => [],
        "dns" => []
    }
}

# general_conf will dump its contents as yaml conf into rb_init_conf.yml

text = <<EOF
This wizard will guide you through the necessary configuration of the device
in order to convert it into a redborder node within a redborder cluster.
It will go through the following required steps: network configuration,
configuration of hostname, domain and DNS, Serf configuration, and finally
the node mode (the mode determines the minimum group of services that make up
the node, giving it more or less weight within the cluster).
Would you like to continue?
EOF

dialog = MRDialog.new
dialog.clear = true
dialog.title = "Configure wizard"
yesno = dialog.yesno(text, 0, 0)

cancel_wizard unless yesno # yesno is "yes" -> true

text = <<EOF
Next, you will be able to configure network settings. If you have
the network configured manually, you can "SKIP" this step and go
to the next step.
Please, Select an option.
EOF

dialog = MRDialog.new
dialog.clear = true
dialog.title = "Configure Network"
dialog.cancel_label = "SKIP"
dialog.no_label = "SKIP"
yesno = dialog.yesno(text, 0, 0)

if yesno # yesno is "yes" -> true
    # Conf for network
    netconf = NetConf.new
    netconf.doit # launch wizard
    cancel_wizard if netconf.cancel
    general_conf["network"]["interfaces"] = netconf.conf

    if general_conf["network"]["interfaces"].size > 1
        static_interface = general_conf["network"]["interfaces"].find { |i| i["mode"] == "static" }
        dhcp_interfaces = general_conf["network"]["interfaces"].select { |i| i["mode"] == "dhcp" }

        #If there is exactly one Static interface and one or more DHCP interfaces, the Static one is automatically chosen.
        # This block would not execute if there is more than one Static interface.
        if static_interface && dhcp_interfaces.size >= 1
            general_conf["network"]["management_interface"] = static_interface["device"]
        else
        # This block executes if the above condition is not met,
        # such as when there are multiple Static interfaces (and/or DHCP).
        # The user is given the option to choose
        interface_options = general_conf["network"]["interfaces"].map { |i| [i["device"]] }
        text = <<EOF
You have multiple network interfaces configured.
Please select one to be used as the management interface.
EOF
        dialog = MRDialog.new
        dialog.clear = true
        dialog.title = "Select Management Interface"
        management_iface = dialog.menu("Choose an interface:", interface_options, 10, 50)

        if management_iface.nil? || management_iface.empty?
            cancel_wizard
        else
            general_conf["network"]["management_interface"] = management_iface
        end
    end
end


    # Conf for DNS
    text = <<EOF
Do you want to configure DNS servers?
If you have configured the network as Dynamic and
you get the DNS servers via DHCP, you should say
'No' to this question.
EOF

    dialog = MRDialog.new
    dialog.clear = true
    dialog.title = "CONFIGURE DNS"
    yesno = dialog.yesno(text, 0, 0)

    if yesno # yesno is "yes" -> true
        # configure dns
        dnsconf = DNSConf.new
        dnsconf.doit # launch wizard
        cancel_wizard if dnsconf.cancel
        general_conf["network"]["dns"] = dnsconf.conf
    else
        general_conf["network"].delete("dns")
    end
end

# Conf for hostname and domain
cloud_address_conf = CloudAddressConf.new
cloud_address_conf.doit # launch wizard
cancel_wizard if cloud_address_conf.cancel
general_conf["cloud_address"] = cloud_address_conf.conf[:cloud_address]

# Confirm
text = <<EOF
You have selected the following parameter values for your configuration:
EOF

# Get interfaces info
unless general_conf["network"]["interfaces"].empty?
    text += "- Networking:\n"
    general_conf["network"]["interfaces"].each do |i|
        text += "    device: #{i["device"]}\n"
        text += "    mode: #{i["mode"]}\n"
        if i["mode"] == "static"
            text += "    ip: #{i["ip"]}\n"
            text += "    netmask: #{i["netmask"]}\n"
            unless i["gateway"].nil? or i["gateway"] == ""
                text += "    gateway: #{i["gateway"]}\n"
            end
        end
        text += "\n"
    end
end

# Get DNS info
unless general_conf["network"]["dns"].nil?
    text += "- DNS:\n"
    general_conf["network"]["dns"].each do |dns|
        text += "    #{dns}\n"
    end
end

text += "\n- Cloud address: #{general_conf["cloud_address"]}\n"

text += "\nPlease, is this configuration ok?\n \n"

dialog = MRDialog.new
dialog.clear = true
dialog.title = "Confirm configuration"
yesno = dialog.yesno(text, 0, 0)

cancel_wizard unless yesno # yesno is "yes" -> true

File.open(CONFFILE, 'w') { |f| f.write general_conf.to_yaml } # Store

# Executing rb_init_conf
command = "#{ENV['RBBIN']}/rb_init_conf"
dialog = MRDialog.new
dialog.clear = false
dialog.title = "Applying configuration"
dialog.prgbox(command, 20, 100, "Executing rb_init_conf")
