#!/bin/sh 

export DEBIAN_FRONTEND=noninteractive

# Check for the latest one available
AUTER_DEB="https://github.com/rackerlabs/auter/releases/download/1.0.0/auter_1.0.0_all.deb"
PACKAGES="curl git cron monit fail2ban dbus jq net-tools ncdu"

# Install base requeriments
mkdir /root/init; cd /root/init

if which apt-get > /dev/null; then
	echo "Install packages: ${PACKAGES}"
	apt-get update ; apt-get -qy install --no-install-recommends ${PACKAGES}
	apt-get -qy install --no-install-recommends linux-image-extra-$(uname -r) || true

	# Install Auter (security updates)
	echo "Install AUTER (security updates)"
	STATUS=$(curl -s -o /tmp/auter.deb -w '%{http_code}' ${AUTER_DEB})
	if [ ${STATUS} -eq 200 ]; then
		dpkg -i /tmp/auter.deb
		rm -f /tmp/auter.deb
	else
		echo "ERROR: Some problem during downloading AUTER" ${STATUS}
	fi

else
  yum install -y  ${PACKAGES} auter
fi

# Clone repo
echo "Bootstrap System - init.sh"
git clone https://github.com/pvillaverde/system-init .

# Configure monit
echo "Configure monit"
cat /root/init/init-monitrc > /etc/monit/monitrc
/etc/init.d/monit restart

# Configure firewall
/root/init/firewall.sh

# Redirecting firewall logs to its own file
sed -i '/RULES.*/a ## Regla para desviar mensajes de iptables\n:msg, startswith, "IPTABLES" -/var/log/iptables.log\n& ~' /etc/rsyslog.conf
systemctl restart rsyslog



# Configure logrotate
echo "Configure logrotate"
cat /root/init/init-logrotate.d-docker > /etc/logrotate.d/docker
cat /root/init/init-logrotate.d-initlog > /etc/logrotate.d/initlog
cat /root/init/init-logrotate.d-iptables > /etc/logrotate.d/iptables

# Tune sysctl
echo "Kernel tune"
cat /root/init/init-sysctl.conf > /etc/sysctl.conf

if ! [ -f /root/init/docker-compose.yml ]; then
  cat <<EOF > /root/init/docker-compose.yml
version: "3.7"
services:
  alpine:
    container_name: \${IMAGE_NAME}
    image: alpine:latest
    restart: always
    command: echo "Yea!, is running"

EOF
fi

# Bootstrap and start
/root/init/init.sh

# Cleanup
echo "Clean up"
rm -Rf /root/init/.git*
rm -f /root/init/init-monitrc*
rm -f /root/init/init-sysctl.conf
rm -f /root/init/init-logrotate.d-docker
rm -f /root/init/init-logrotate.d-initlog
rm -f /root/init/bootstrap*
rm -f /root/init/README.md

if which apt-get > /dev/null; then
	apt-get -qy --purge autoremove || true
fi
echo 'alias dc="docker-compose"' >> ~/.bashrc
# Timestamp on history
echo 'HISTTIMEFORMAT="%d/%m/%y %T "' >> ~/.bashrc  # or respectively
echo 'HISTTIMEFORMAT="%F %T "' >> ~/.bashrc
echo 'HISTFILE="$HOME/.bash_history.$SUDO_USER"' >> ~/.bashrc # Keep separated history files

source ~/.bashrc