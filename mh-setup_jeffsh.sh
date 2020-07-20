#!/usr/bin/env bash
# This tool is to setup new Managed Hosting servers during the initial Launch Assist setup.

### COLORS ###
NC=$(echo -en '\033[0m')       		# Reset to normal TTY
RED=$(echo -en '\033[01;31m')		# Bold Red
GRN=$(echo -en '\033[01;32m')		# Bold Green
YEL=$(echo -en '\033[01;33m')		# Bold Yellow
BLU=$(echo -en '\033[01;94m')		# Bold Light Blue
CYA=$(echo -en '\033[01;36m')		# Bold Cyan
MAG=$(echo -en '\033[01;35m')		# Bold Magenta
WHT=$(echo -en '\033[01;37m')	# Bold White
LTB=$(echo -en '\033[94m')			# Light Blue
BLB=$(echo -en '\e[44m')				# Blue Background
ULNE=$(echo -en '\033[4m')			# Underline
OVW=$(echo -en '\033[0K\r')			# Overwrite existing line. Useful for countdowns....

mh-setup() {
	# finish any remaining yum transactions
	echo -en "${CYA}Running yum-complete-transaction...${NC}"
	yum-complete-transaction --cleanup-only > /dev/null 2>&1
	echo -e "${GRN}DONE${NC}"

	# Clean up duplicate RPM packages (seems to only be an issue on new VPS's):
	echo -en "${CYA}Cleaning duplicate RPM packages...${NC}"
	package-cleanup -y --cleandupes > /dev/null 2>&1
	echo -e "${GRN}DONE${NC}"

	# clear all cached yum packages
	echo -en "${CYA}Cleaning YUM's cache...${NC}"
	yum clean all > /dev/null 2&>1
	echo -e "${GRN}DONE${NC}"

	# Make sure FirewallD is removed as it conflicts with other firewalls installed.
	echo -en "${CYA}Removing FirewallD...${NC}"
	yum remove -y firewalld > /dev/null 2>&1
	service apf restart > /dev/nulll 2>&1
	echo -e "${GRN}DONE${NC}"

	# update yum packages ( why not `yum update`? -> upgrade removes any obsoletes, update does not )
	echo -en "${CYA}Running YUM package upgrade...${NC}"
	yum -y upgrade > /dev/null 2>&1
	echo -e "${GRN}DONE${NC}"

	# Found an issue with cURL missing ca certs and this fixes it. Running to ensure it's addressed.
	echo -en "${CYA}YUM reinstalling CA Certificates and OpenSSL...${NC}"
	yum -y reinstall ca-certificates openssl > /dev/null 2>&1
	echo -e "${GRN}DONE${NC}"

	# VPS's are not being provisioned with these Apache modules and tools some, like bc, are needed by some of our RADS...
	echo -en "${CYA}Installing the usually missing suspects via YUM...${NC}"
	yum -y install ea-apache24-mod_headers ea-apache24-mod_deflate ea-apache24-mod_expires ea-apache24-mod_http2 ea-apache24-mod_version ea-apache24-mod_cloudflare bc > /dev/null 2>&1
	echo -e "${GRN}DONE${NC}"

	# Check if dedicated server or VPS
	if [[ ! -d '/proc/vz/' ]]; then
		echo -e "${CYA}Dedicated Server - Installing Perl packages for IMH scripts on Dedicated...${NC}"
		# on a dedicated server
		# needed Perl packages for IMH scripts
		echo -en "  ${CYA}CPAN installing JSON::XS...${NC}"
		yes 'no' | cpan -i JSON::XS > /dev/null 2>&1
		echo -e "${GRN}DONE${NC}"
		
		# Check if KernelCare is installed. Should be installed for all dedi's since February 2020.
		kcare=$(lsmod | grep kcare)
		if [ ! -z "${kcare}" ]; then
			# update kernel ( noticed kcarectl not enabled on new G3's, why's that? )
			echo -e "  ${BLU}KernelCare is installed!!${NC}"
			echo -en "  ${CYA}Updating kernel using kcarectl...${NC}"
			kcarectl -u > /dev/null 2>&1
			echo -e "${GRN}DONE${NC}"
		else
			echo -e "  ${RED}KernelCare is not installed. Double check and create a Jira ticket with T3 Operations if missing.${NC}"
		fi
	else
		echo -e "${CYA}VPS Server - Installing Perl packages for IMH scripts on VPS...${NC}"
		# on a VPS    
		# needed Perl packages for IMH scripts
		echo -e "  ${CYA}YUM installing various Perl modules:${NC}"
		echo -en "  ${BLU}perl-File-Slurp perl-YAML perl-YAML-Syck perl-Template-Toolkit...${NC}"
		yum -y install perl-File-Slurp perl-YAML perl-YAML-Syck perl-Template-Toolkit > /dev/null 2>&1
		echo -e "${GRN}DONE${NC}"

		# more needed Perl packages for IMH scripts
		echo -e "  ${CYA}CPAN installing various Perl modules:${NC}"
		echo -en "  ${BLU}Switch CDB_File LWP::Protocol::https IO::Scalar Date::Parse Text::Template...${NC}"
		yes 'no' | cpan -i Switch CDB_File LWP::Protocol::https IO::Scalar Date::Parse Text::Template > /dev/null 2>&1
		echo -e "${GRN}DONE${NC}"
		
		# Delete the ce7clone.inmotionhosting.com DNS entry from the system. This is not needed.
		echo -en "  ${CYA}Removing DNS zone file for ce7clone.inmotionhosting.com...${NC}"
		rm -f /var/named/ce7clone.inmotionhosting.com.db > /dev/null 2>&1
		echo -e "${GRN}DONE${NC}"
	fi  

	# check that rsyslog is running
	if [ ! -f /var/log/messages ]; then
		echo -en "${CYA}Found potential issue with rsyslog not logging, addressing...${NC}"
		rm -f /var/lib/rsyslog/imjournal.state
		systemctl restart rsyslog
		echo -e "${GRN}DONE${NC}"
	fi

	# update quotas
	echo -en "${CYA}Update cPanel disk quotas...${NC}"
	/scripts/fixquotas > /dev/null 2>&1
	echo -e "${GRN}DONE${NC}"

	# get apache mpm, install mpm_event if it's not installed
	mpm=$(yum list installed | grep mpm_worker | awk {'print $1'})
	if [[ "$mpm" != 'ea-apache24-mod_mpm_event' ]] && [[ -z $mpm ]]; then
		echo -en "${CYA}Found Apache mpm_worker, changing to mpm_event...${NC}"
		yum -y swap $mpm ea-apache24-mod_mpm_event > /dev/null 2>&1
		echo -e "${GRN}DONE${NC}"
	fi
	
	# make PHP adjustments ( memory_limit > 32m, etc )
	echo -en "${CYA}Adjusting PHP Settings for all versions of PHP installed...${NC}"
	(
		IFS=$'\n'
		for PHP_INI_FILE in $(find /opt/cpanel/ea-php*/root/etc/ -maxdepth 1 -type f -name php.ini); do
			sed -ine '/^ *\(short_open_tag\|asp_tags\|expose_php\|display_errors\)/s/=.*/= Off/; /^ *\(zlib.output_compression\|allow_url_fopen\|allow_url_include\)/s/=.*/= On/; s/\;zlib.output_compression = Off/zlib.output_compression = On/; /^ *max_execution_time/s/=.*/= 300/; /^ *max_input_time/s/=.*/= 120/; /^ *max_input_vars/s/=.*/= 4000/; s/\; max_input_vars = 1000/max_input_vars = 4000/; /^ *memory_limit/s/=.*/= 256M/; s/error_reporting = .*/error_reporting = E_ALL \& ~E_NOTICE \& ~E_DEPRECATED \& ~E_STRICT/; /^ *\(post_max_size\|upload_max_filesize\)/s/=.*/= 256M/' $PHP_INI_FILE
		done
		/scripts/php_fpm_config --rebuild > /dev/null 2>&1
		/scripts/restartsrv_apache_php_fpm > /dev/null 2>&1
	)
	echo -e "${GRN}DONE${NC}"

	# remove cPanel php include path files as they are not needed and have caused issues before
	echo -en "${CYA}Removing cPanel PHP include path files as they are not needed and have caused issues before...${NC}"
	find /etc/apache2/conf.d/userdata -name cp_php_magic_include_path.conf -type f -delete 2>/dev/null
	echo -e "${GRN}DONE${NC}"

	# restarting this service can speed up ssh logins
	echo -en "${CYA}Restarting systemd-logind.service...${NC}"
	systemctl restart systemd-logind.service
	echo -e "${GRN}DONE${NC}"

	# check that existence of zone file in ns.inmotionhosting.com for hostname
	if ! dig @ns1.inmotionhosting.com $(hostname) +short > /dev/null 2>&1; then
		echo -e "${RED}No A record found for $(hostname) in ns1.inmotionhosting.com${NC}"
	fi

	# imh-nginx changes - As of February 2020, imh-ultrastack-ded shoudl be installed, not imh-nginx and tools. If not found, remove it the old and correct it.
	echo -e "\n${CYA}-----------------${NC}"
	echo -e "${CYA}NGINX Check${NC}"
	echo -e "${CYA}-----------------${NC}"
	if [[ -d /var/nginx ]]; then
		# Make sure it's the new IMH Ultrastack installed.
		ultrastack=$(yum list installed | grep imh-ultrastack-ded | awk {'print $1'})
		if [[ "$ultrastack" != 'imh-ultrastack-ded.x86_64' ]]; then
			echo -en "${YEL}Found old installation of imh-nginx instead of imh-ultrastack, correcting...${NC}"
			sed -i 's/apache_port=.*/apache_port=0.0.0.0:80/' /var/cpanel/cpanel.config > /dev/null 2>&1
			sed -i 's/apache_ssl_port=.*/apache_ssl_port=0.0.0.0:443/' /var/cpanel/cpanel.config > /dev/null 2>&1
			sed -i '/\#IMH .*/d' /etc/apache2/conf.d/includes/pre_main_global.conf > /dev/null 2>&1
			sed -i '/LogFormat .*/d' /etc/apache2/conf.d/includes/pre_main_global.conf > /dev/null 2>&1
			sed -i '/RemoteIPHeader .*/d' /etc/apache2/conf.d/includes/pre_main_global.conf > /dev/null 2>&1
			sed -i '/RemoteIPInternalProxy .*/d' /etc/apache2/conf.d/includes/pre_main_global.conf > /dev/null 2>&1
			yum -y remove imh-nginx imh-ngxconf imh-ngxutil imh-cpanel-cache-manager imh-ngxstats > /dev/null 2>&1
			/scripts/rebuildhttpdconf > /dev/null 2>&1
			/scripts/restartsrv_httpd > /dev/null 2>&1
			service httpd restart > /dev/null 2>&1
			/scripts/php_fpm_config --rebuild > /dev/null 2>&1
			/scripts/restartsrv_apache_php_fpm > /dev/null 2>&1
			sleep 10
			yum -y install imh-ultrastack-ded  > /dev/null 2>&1
			yum -y install ea-apache24-mod_remoteip.x86_64 > /dev/null 2>&1
			echo -e "${GRN}DONE${NC}"
		fi

		# Fix NGINX Safari issue when using HTTP/2 and add entry so that Cloudflare domains pass the correct visitor IP to Apache logs.
		echo -en "${CYA}Setting up NGINX for HTTP/2 and Cloudflare...${NC}"
		echo -e "\nproxy_hide_header Upgrade;\n" >> /etc/nginx/conf.d/nginx-includes.conf;
		echo -e "\nreal_ip_header CF-Connecting-IP;\n" >> /etc/nginx/conf.d/cloudflare.conf;
		echo -e "${GRN}DONE${NC}"

		echo -en "${CYA}IMH NGINX conf rebuild underway...${NC}"
		service nginx restart > /dev/null 2>&1
		ngxconf -Rrd --fork > /dev/null 2>&1
		echo -e "${GRN}DONE${NC}"
	else
		echo -e "${CYA}NGINX not found. Skipping.${NC}"
	fi

	# check for DNS clustering
	# if /var/cpanel/cluster is 4 bytes, it's empty, and clustering is not setup
	echo -e "\n${CYA}-----------------${NC}"
	echo -e "${CYA}DNS Cluster Check${NC}"
	echo -e "${CYA}-----------------${NC}"
	#if [[ $(du -s /var/cpanel/cluster | awk {'print $1'}) == 4 ]]; then
	if [[ -d /var/cpanel/cluster/root ]]; then 
		echo -e "${GRN}DNS clustering is setup${NC}"
		echo -e "${BLU}Cluster User:${NC} $(cat /var/cpanel/cluster/root/config/imh | grep user | cut -d= -f 2)"
	else
		echo -e "${RED}DNS clustering does not appear to be setup${NC}"
	fi

	# check for cPanel license
	echo -e "\n${CYA}--------------------${NC}"
	echo -e "${CYA}cPanel License Check${NC}"
	echo -e "${CYA}--------------------${NC}"
	cplicense=$(lynx -dump https://verify.cpanel.net/app/verify?ip=$(hostname -i) | grep -i "inmotion")
	if [[ -e ${cplicense} ]]; then
		echo -e "${RED}cPanel license does not appear to be active${NC}"
		echo -e "${YEL}Trying to force the cPanel license update...${NC}"
			# make sure cPanel license is active
			/usr/local/cpanel/cpkeyclt --force
	else
		echo -e "${GRN}cPanel license is active${NC}"
	fi
	
	# make sure service SSLs are working
	echo -en "\n${CYA}Making sure Service SSLs are working...${NC}"
	/usr/local/cpanel/bin/checkallsslcerts --allow-retry > /dev/null 2>&1
	echo -e "${GRN}DONE${NC}"

	# update cPanel
	echo -en "${CYA}Starting UPCP process in the background...${NC}"
	/scripts/upcp --force --bg > /dev/null 2>&1
	echo -e "${GRN}DONE${NC}"
	
	# Show Server IP count.
	echo -e "${CYA}All Server IPs:${NC}"
	/scripts/ipusage | awk '{print $1}'
};

mh-setup

exit 0