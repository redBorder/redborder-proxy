%undefine __brp_mangle_shebangs

Name: redborder-proxy
Version: %{__version}
Release: %{__release}%{?dist}
BuildArch: noarch
Summary: Main package for redborder proxy

License: AGPL 3.0
URL: https://github.com/redBorder/redborder-proxy
Source0: %{name}-%{version}.tar.gz

Requires: bash dialog dmidecode rsync nc telnet redborder-common redborder-chef-client redborder-rubyrvm redborder-cli rb-register dhclient
Requires: alternatives java-1.8.0-openjdk java-1.8.0-openjdk-devel
Requires: network-scripts network-scripts-teamd
Requires: chef-workstation
Requires: redborder-cgroups

%description
%{summary}

%prep
%setup -qn %{name}-%{version}

%build

%install
mkdir -p %{buildroot}/etc/redborder
mkdir -p %{buildroot}/usr/lib/redborder/bin
mkdir -p %{buildroot}/usr/lib/redborder/scripts
mkdir -p %{buildroot}/usr/lib/redborder/lib
mkdir -p %{buildroot}/etc/profile.d
mkdir -p %{buildroot}/var/chef/cookbooks
mkdir -p %{buildroot}/etc/chef/
install -D -m 0644 resources/redborder-proxy.sh %{buildroot}/etc/profile.d
install -D -m 0644 resources/dialogrc %{buildroot}/etc/redborder
cp resources/bin/* %{buildroot}/usr/lib/redborder/bin
cp resources/scripts/* %{buildroot}/usr/lib/redborder/scripts
cp -r resources/etc/chef %{buildroot}/etc/
chmod 0755 %{buildroot}/usr/lib/redborder/bin/*
chmod 0755 %{buildroot}/usr/lib/redborder/scripts/*
install -D -m 0644 resources/lib/rb_wiz_lib.rb %{buildroot}/usr/lib/redborder/lib
install -D -m 0644 resources/lib/rb_config_utils.rb %{buildroot}/usr/lib/redborder/lib
install -D -m 0644 resources/lib/rb_functions.sh %{buildroot}/usr/lib/redborder/lib
install -D -m 0644 resources/systemd/rb-init-conf.service %{buildroot}/usr/lib/systemd/system/rb-init-conf.service
install -D -m 0755 resources/lib/dhclient-enter-hooks %{buildroot}/usr/lib/redborder/lib/dhclient-enter-hooks

%pre

%post
if ls /opt/chef-workstation/embedded/lib/ruby/gems/3.1.0/specifications/default/openssl-3.0.1.* 1> /dev/null 2>&1; then
  rm -f /opt/chef-workstation/embedded/lib/ruby/gems/3.1.0/specifications/default/openssl-3.0.1.*
fi
case "$1" in
  1)
    # This is an initial install.
    :
  ;;
  2)
    # This is an upgrade.
    CDOMAIN_FILE="/etc/redborder/cdomain"

    if [ -f "$CDOMAIN_FILE" ]; then
      SUFFIX=$(cat "$CDOMAIN_FILE")
    else
      SUFFIX="redborder.cluster"
    fi

    NEW_DOMAIN="http2k.${SUFFIX}"

    sed -i -E "s/\bhttp2k\.service\b/${NEW_DOMAIN}/" /etc/hosts
  ;;
esac

/usr/lib/redborder/bin/rb_rubywrapper.sh -c
# adjust kernel printk settings for the console
echo "kernel.printk = 1 4 1 7" > /usr/lib/sysctl.d/99-redborder-printk.conf
/sbin/sysctl --system > /dev/null 2>&1

%posttrans
update-alternatives --set java $(find /usr/lib/jvm/*java-1.8.0-openjdk* -name "java"|head -n 1)

%files
%defattr(0755,root,root)
/usr/lib/redborder/bin
/usr/lib/redborder/scripts
%defattr(0755,root,root)
/etc/profile.d/redborder-proxy.sh
/usr/lib/redborder/lib/dhclient-enter-hooks
%defattr(0644,root,root)
/etc/chef
/etc/redborder
/usr/lib/redborder/lib/rb_wiz_lib.rb
/usr/lib/redborder/lib/rb_config_utils.rb
/usr/lib/redborder/lib/rb_functions.sh
/usr/lib/systemd/system/rb-init-conf.service
%doc

%changelog
* Tue Apr 22 2025 Rafael Gómez <rgomez@redborder.com> - 0.6.1-1
- Remove openssl gemspec file handling from chef-workstation package
* Fri Mar 28 2025 Vicente Mesa, José Navarro <vimesa@redborder.com, jnavarro@redborder.com> - 0.6.0-1
- Chef-workstation update handling conflict with embedded openssl gemspec
* Mon Apr 14 2025 Rafael Gómez <rgomez@redborder.com> - 0.5.0-1
- Add domain configuration update during package upgrade for http2k
* Thu Dec 14 2023 Miguel Álvarez <malvarez@redborder.com> - 0.1.0-1
- Add cgroups
* Tue Nov 21 2023 Vicente Mesa <vimesa@redborder.com> - 0.0.9-1
- Add dhclient
* Tue Nov 14 2023 Miguel Negron <manegron@redborder.com> - 0.0.8-1
- add networkscripts
* Wed Sep 13 2023 Julio Peralta <jperalta@redborder.com> - 0.0.7-1
- Changed ZK_host, removed IF="," and ".node" inside rb_get_zkinfo.sh
* Thu Apr 13 2023 Luis Blanco <ljblanco@redborder.com> -
- disassociate added
* Mon Mar 21 2021 Miguel Negron <manegron@redborder.com> - 0.0.1-1
- first spec version
