#!/usr/bin/env bash
iptables -F
# Añadir de nuevo las reglas de docker
systemctl restart docker

declare -A inputRules_0000=([proto]="tcp" [port]="22" [name]="SSH" )
declare -A inputRules_0001=([proto]="tcp" [port]="80" [name]="HTTP" )
declare -A inputRules_0002=([proto]="tcp" [port]="443" [name]="HTTPS" )

declare -n inputRules
for inputRules in ${!inputRules@}; do
    iptables -A INPUT -p ${inputRules[proto]} --dport ${inputRules[port]} -j ACCEPT && echo "IPv4_Entrada_${inputRules[name]} (${inputRules[proto]} ${inputRules[port]})"
    ip6tables -A INPUT -p ${inputRules[proto]} --dport ${inputRules[port]} -j ACCEPT && echo "IPv6_Entrada_${inputRules[name]} (${inputRules[proto]} ${inputRules[port]})"
done

#Permitir INPUT en loopback
iptables -A INPUT -i lo -j ACCEPT && echo "IPv4_Entrada_Loopback"
ip6tables -A INPUT -i lo -j ACCEPT && echo "IPv6_Entrada_Loopback"
#Permitimos os paquetes de comunicacións previamente establecidas (por portos de clientes)
iptables -A INPUT -p tcp --dport 1024:65535     -m conntrack --ctstate ESTABLISHED -j ACCEPT && echo "IPv4_Entrada_TCP_establecidas"
iptables -A INPUT -p udp --dport 1024:65535     -m conntrack --ctstate ESTABLISHED -j ACCEPT && echo "IPv4_Entrada_UDP_establecidas"
iptables -A INPUT -p icmp -j ACCEPT && echo "IPv4_Entrada_PINGs"
ip6tables -A INPUT -p tcp --dport 1024:65535     -m conntrack --ctstate ESTABLISHED -j ACCEPT && echo "IPv6_Entrada_TCP_establecidas"
ip6tables -A INPUT -p udp --dport 1024:65535     -m conntrack --ctstate ESTABLISHED -j ACCEPT && echo "IPv6_Entrada_UDP_establecidas"
ip6tables -A INPUT -p icmpv6                     -m conntrack --ctstate ESTABLISHED -j ACCEPT && echo "IPv6_Entrada_ICMP_establecidas"
## ICMPv6
ip6tables -A INPUT -p icmpv6 --icmpv6-type destination-unreachable -j ACCEPT
ip6tables -A INPUT -p icmpv6 --icmpv6-type packet-too-big -j ACCEPT
ip6tables -A INPUT -p icmpv6 --icmpv6-type time-exceeded -j ACCEPT
ip6tables -A INPUT -p icmpv6 --icmpv6-type parameter-problem -j ACCEPT


# Allow some other types in the INPUT chain, but rate limit.
ip6tables -A INPUT -p icmpv6 --icmpv6-type echo-request -m limit --limit 900/min -j ACCEPT
ip6tables -A INPUT -p icmpv6 --icmpv6-type echo-reply -m limit --limit 900/min -j ACCEPT


# Allow others ICMPv6 types but only if the hop limit field is 255.

ip6tables -A INPUT -p icmpv6 --icmpv6-type router-advertisement -m hl --hl-eq 255 -j ACCEPT
ip6tables -A INPUT -p icmpv6 --icmpv6-type neighbor-solicitation -m hl --hl-eq 255 -j ACCEPT
ip6tables -A INPUT -p icmpv6 --icmpv6-type neighbor-advertisement -m hl --hl-eq 255 -j ACCEPT
ip6tables -A INPUT -p icmpv6 --icmpv6-type redirect -m hl --hl-eq 255 -j ACCEPT

#Resto
iptables -A INPUT ! -p icmp -j LOG --log-prefix "IPTABLES IN "
iptables -A INPUT -j DROP
ip6tables -A INPUT ! -p icmp -j LOG --log-prefix "IPTABLESv6 IN "
ip6tables -A INPUT -j DROP
echo "#############################################################"
echo "##################### Firewall OUTPUT #######################"
echo "#############################################################"
#
#Permitir OUTPUT en loopback
iptables -A OUTPUT -o lo -j ACCEPT && echo "IPv4_Saída_Loopback"
iptables -A OUTPUT -o lo -j ACCEPT && echo "IPv6_Saída_Loopback"
# Permitense conexións novas (O servidor actúa como cliente) e as establecidas previamente (Que entraron, ou dunha comunicación saínte)
iptables -A OUTPUT -p udp --sport 1024:65535    -m conntrack --ctstate NEW,ESTABLISHED  -j ACCEPT && echo "IPv4_Saída_UDP_CLIENTE"
iptables -A OUTPUT -p tcp --sport 1024:65535    -m conntrack --ctstate NEW,ESTABLISHED  -j ACCEPT && echo "IPv4_Saída_TCP_CLIENTE"
iptables -A OUTPUT -p udp                       -m conntrack --ctstate ESTABLISHED      -j ACCEPT && echo "IPv4_Saída_UDP_RESPOSTAS_SERVER"
iptables -A OUTPUT -p tcp                       -m conntrack --ctstate ESTABLISHED      -j ACCEPT && echo "IPv4_Saída_TCP_RESPOSTAS_SERVER"
iptables -A OUTPUT -p icmp                      -m conntrack --ctstate NEW,ESTABLISHED  -j ACCEPT && echo "IPv4_Saída_Peticions_ICMP"

ip6tables -A OUTPUT -p udp --sport 1024:65535    -m conntrack --ctstate NEW,ESTABLISHED  -j ACCEPT && echo "IPv6_Saída_UDP_CLIENTE"
ip6tables -A OUTPUT -p tcp --sport 1024:65535    -m conntrack --ctstate NEW,ESTABLISHED  -j ACCEPT && echo "IPv6_Saída_TCP_CLIENTE"
ip6tables -A OUTPUT -p udp                       -m conntrack --ctstate ESTABLISHED      -j ACCEPT && echo "IPv6_Saída_UDP_RESPOSTAS_SERVER"
ip6tables -A OUTPUT -p tcp                       -m conntrack --ctstate ESTABLISHED      -j ACCEPT && echo "IPv6_Saída_TCP_RESPOSTAS_SERVER"
ip6tables -A OUTPUT -p icmpv6                    -m conntrack --ctstate NEW,ESTABLISHED  -j ACCEPT && echo "IPv6_Saída_Peticions_ICMP"
ip6tables -A OUTPUT -p icmpv6                    -m conntrack --ctstate NEW,ESTABLISHED  -j ACCEPT && echo "IPv6 - Peticions_ICMP"
ip6tables -A OUTPUT -p icmpv6 -j ACCEPT && echo "IPv6 - Salida ping6"
#
#
#Resto
iptables -A OUTPUT -j LOG --log-prefix "IPTABLES OUT "
iptables -A OUTPUT -j DROP
ip6tables -A OUTPUT -j LOG --log-prefix "IPTABLESv6 OUT "
ip6tables -A OUTPUT -j DROP
#
#
echo "######################## FORWARD ###########################"

iptables -A FORWARD -j LOG --log-prefix "IPTABLES FORWARD "
iptables -A FORWARD -j DROP
ip6tables -A FORWARD -j LOG --log-prefix "IPTABLESv6 FORWARD "
ip6tables -A FORWARD -j DROP

if which apt-get > /dev/null; then
	apt-get install iptables-persistent
	systemctl enable netfilter-persistent && systemctl start netfilter-persistent
	iptables-save > /etc/iptables/rules.v4
	ip6tables-save > /etc/iptables/rules.v6
	systemctl status netfilter-persistent
else
	systemctl stop firewalld &&	systemctl disable firewalld
	yum install iptables-services
	systemctl enable iptables && systemctl start iptables
	systemctl enable ip6tables && systemctl start ip6tables
	iptables-save > /etc/sysconfig/iptables
	ip6tables-save > /etc/sysconfig/ip6tables
	systemctl status iptables
fi
