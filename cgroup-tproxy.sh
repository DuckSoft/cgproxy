#!/bin/bash
print_help(){
cat << 'DOC'
#############################################################################
# 
# 1. This script need cgroup v2 
# 
# 2. Listening port is expected to accept iptables TPROXY, while REDIRECT 
#    will not work in this script, because REDIRECT only support tcp/ipv4
# 
# 3. TPROXY need root or special capability whatever process is listening on port
#    v2ray as example: 
#       sudo setcap "cap_net_bind_service=+ep cap_net_admin=+ep" /usr/lib/v2ray/v2ray
# 
# 4. this script will proxy anything running in specific cgroup
# 
# script usage:
#     cgroup-tproxy.sh [--help|--config|stop]
#     --config=FILE
#           load config from file
#     --help
#           show help info
#     stop
#           clean then stop
# 
# proxy usage:
#     cgproxy <program>
# 
#############################################################################
DOC
}

## check root
[ ! $(id -u) -eq 0 ] && { >&2 echo "iptables: need root to modify iptables";exit -1; }

## any process in this cgroup will be proxied
if [ -z ${cgroup_proxy+x} ]; then  
    cgroup_proxy="/proxy.slice"
else
    IFS=':' read -r -a cgroup_proxy     <<< "$cgroup_proxy"
fi

## any process in this cgroup will not be proxied
if [ -z ${cgroup_noproxy+x} ]; then  
    cgroup_noproxy="/noproxy.slice"
else
    IFS=':' read -r -a cgroup_noproxy   <<< "$cgroup_noproxy"
fi

# allow as gateway for local network
[ -z ${enable_gateway+x} ] && enable_gateway=false

## some variables
[ -z ${port+x} ] && port=12345

## some options
[ -z ${enable_dns+x} ]  && enable_dns=true
[ -z ${enable_tcp+x} ]  && enable_tcp=true
[ -z ${enable_udp+x} ]  && enable_udp=true
[ -z ${enable_ipv4+x} ] && enable_ipv4=true
[ -z ${enable_ipv6+x} ] && enable_ipv6=true

##
get_available_route_table(){
    table=10007 
    while true; do 
        ip route show table $table &> /dev/null && ((table++)) || { echo $table && break; }
    done
}

## mark/route things
[ -z ${table+x} ]       && table=10007 # just a prime number
[ -z ${fwmark+x} ]      && fwmark=0x9973
[ -z ${mark_newin+x} ]  && mark_newin=0x9967


# echo "table: $table fwmark: $fwmark, mark_newin: $mark_newin"

## cgroup things
[ -z ${cgroup_mount_point+x} ] && cgroup_mount_point=$(findmnt -t cgroup2 -n -o TARGET | head -n 1)
[ -z $cgroup_mount_point ] && { >&2 echo "iptables: no cgroup2 mount point available"; exit -1; }
[ ! -d $cgroup_mount_point ] && mkdir -p $cgroup_mount_point
[ "$(findmnt -M $cgroup_mount_point -n -o FSTYPE)" != "cgroup2" ] && mount -t cgroup2 none $cgroup_mount_point
[ "$(findmnt -M $cgroup_mount_point -n -o FSTYPE)" != "cgroup2" ] && { >&2 echo "iptables: mount $cgroup_mount_point failed"; exit -1; }

stop(){
    iptables -t mangle -L TPROXY_PRE &> /dev/null || return
    echo "iptables: cleaning tproxy iptables"
    iptables -t mangle -D PREROUTING -j TPROXY_PRE
    iptables -t mangle -D OUTPUT -j TPROXY_OUT
    iptables -t mangle -F TPROXY_PRE
    iptables -t mangle -F TPROXY_OUT
    iptables -t mangle -F TPROXY_ENT
    iptables -t mangle -X TPROXY_PRE
    iptables -t mangle -X TPROXY_OUT
    iptables -t mangle -X TPROXY_ENT
    ip6tables -t mangle -D PREROUTING -j TPROXY_PRE
    ip6tables -t mangle -D OUTPUT -j TPROXY_OUT
    ip6tables -t mangle -F TPROXY_PRE
    ip6tables -t mangle -F TPROXY_OUT
    ip6tables -t mangle -F TPROXY_ENT
    ip6tables -t mangle -X TPROXY_PRE
    ip6tables -t mangle -X TPROXY_OUT
    ip6tables -t mangle -X TPROXY_ENT
    ip rule delete fwmark $fwmark lookup $table
    ip route flush table $table
    ip -6 rule delete fwmark $fwmark lookup $table
    ip -6 route flush table $table
    ## may not exist, just ignore, and tracking their existence is not reliable
    iptables -t nat -D POSTROUTING -m owner ! --socket-exists -j MASQUERADE &> /dev/null
    ip6tables -t nat -D POSTROUTING -m owner ! --socket-exists -s fc00::/7 -j MASQUERADE &> /dev/null
    ## unmount cgroup2
    [ "$(findmnt -M $cgroup_mount_point -n -o FSTYPE)" = "cgroup2" ] && umount $cgroup_mount_point
}

## parse parameter
for i in "$@"
do
case $i in
    stop)
        stop
        exit 0
        ;;
    --config=*)
        config=${i#*=}
        source $config
        ;;
    --help)
        print_help
        exit 0
        ;;
esac
done

## TODO cgroup need to exists before using in iptables since 5.6.5, maybe it's bug
## only create the first one in arrary
test -d $cgroup_mount_point$cgroup_proxy    || mkdir $cgroup_mount_point$cgroup_proxy   || exit -1; 
test -d $cgroup_mount_point$cgroup_noproxy  || mkdir $cgroup_mount_point$cgroup_noproxy || exit -1; 

## filter cgroup that not exist
_cgroup_noproxy=()
for cg in ${cgroup_noproxy[@]}; do
    test -d $cgroup_mount_point$cg && _cgroup_noproxy+=($cg) || { >&2 echo "iptables: $cg not exist, ignore";}
done
unset cgroup_noproxy && cgroup_noproxy=${_cgroup_noproxy[@]}

## filter cgroup that not exist
_cgroup_proxy=()
for cg in ${cgroup_proxy[@]}; do
    test -d $cgroup_mount_point$cg && _cgroup_proxy+=($cg) || { >&2 echo "iptables: $cg not exist, ignore";}
done
unset cgroup_proxy && cgroup_proxy=${_cgroup_proxy[@]}


echo "iptables: applying tproxy iptables"
## use TPROXY
#ipv4#
ip rule add fwmark $fwmark table $table
ip route add local default dev lo table $table
iptables -t mangle -N TPROXY_ENT
iptables -t mangle -A TPROXY_ENT -p tcp -j TPROXY --on-ip 127.0.0.1 --on-port $port --tproxy-mark $fwmark
iptables -t mangle -A TPROXY_ENT -p udp -j TPROXY --on-ip 127.0.0.1 --on-port $port --tproxy-mark $fwmark

iptables -t mangle -N TPROXY_PRE
iptables -t mangle -A TPROXY_PRE -m socket --transparent -j MARK --set-mark $fwmark
iptables -t mangle -A TPROXY_PRE -m socket --transparent -j RETURN
iptables -t mangle -A TPROXY_PRE -p icmp -j RETURN
iptables -t mangle -A TPROXY_PRE -p udp --dport 53 -j TPROXY_ENT
iptables -t mangle -A TPROXY_PRE -p tcp --dport 53 -j TPROXY_ENT
iptables -t mangle -A TPROXY_PRE -m addrtype --dst-type LOCAL -j RETURN
iptables -t mangle -A TPROXY_PRE -m addrtype ! --dst-type UNICAST -j RETURN
iptables -t mangle -A TPROXY_PRE -j TPROXY_ENT
iptables -t mangle -A PREROUTING -j TPROXY_PRE

iptables -t mangle -N TPROXY_OUT
iptables -t mangle -A TPROXY_OUT -p icmp -j RETURN
iptables -t mangle -A TPROXY_OUT -m connmark --mark  $mark_newin -j RETURN
iptables -t mangle -A TPROXY_OUT -m addrtype --dst-type LOCAL -j RETURN
iptables -t mangle -A TPROXY_OUT -m addrtype ! --dst-type UNICAST -j RETURN
for cg in ${cgroup_noproxy[@]}; do
iptables -t mangle -A TPROXY_OUT -m cgroup --path $cg -j RETURN
done
for cg in ${cgroup_proxy[@]}; do
iptables -t mangle -A TPROXY_OUT -m cgroup --path $cg -j MARK --set-mark $fwmark
done
iptables -t mangle -A OUTPUT -j TPROXY_OUT

#ipv6#
ip -6 rule add fwmark $fwmark table $table
ip -6 route add local default dev lo table $table
ip6tables -t mangle -N TPROXY_ENT
ip6tables -t mangle -A TPROXY_ENT -p tcp -j TPROXY --on-ip ::1 --on-port $port --tproxy-mark $fwmark
ip6tables -t mangle -A TPROXY_ENT -p udp -j TPROXY --on-ip ::1 --on-port $port --tproxy-mark $fwmark

ip6tables -t mangle -N TPROXY_PRE
ip6tables -t mangle -A TPROXY_PRE -m socket --transparent -j MARK --set-mark $fwmark
ip6tables -t mangle -A TPROXY_PRE -m socket --transparent -j RETURN
ip6tables -t mangle -A TPROXY_PRE -p icmpv6 -j RETURN
ip6tables -t mangle -A TPROXY_PRE -p udp --dport 53 -j TPROXY_ENT
ip6tables -t mangle -A TPROXY_PRE -p tcp --dport 53 -j TPROXY_ENT
ip6tables -t mangle -A TPROXY_PRE -m addrtype --dst-type LOCAL -j RETURN
ip6tables -t mangle -A TPROXY_PRE -m addrtype ! --dst-type UNICAST -j RETURN
ip6tables -t mangle -A TPROXY_PRE -j TPROXY_ENT
ip6tables -t mangle -A PREROUTING -j TPROXY_PRE

ip6tables -t mangle -N TPROXY_OUT
ip6tables -t mangle -A TPROXY_OUT -p icmpv6 -j RETURN
ip6tables -t mangle -A TPROXY_OUT -m connmark --mark  $mark_newin -j RETURN
ip6tables -t mangle -A TPROXY_OUT -m addrtype --dst-type LOCAL -j RETURN
ip6tables -t mangle -A TPROXY_OUT -m addrtype ! --dst-type UNICAST -j RETURN
for cg in ${cgroup_noproxy[@]}; do
ip6tables -t mangle -A TPROXY_OUT -m cgroup --path $cg -j RETURN
done
for cg in ${cgroup_proxy[@]}; do
ip6tables -t mangle -A TPROXY_OUT -m cgroup --path $cg -j MARK --set-mark $fwmark
done
ip6tables -t mangle -A OUTPUT -j TPROXY_OUT

## allow to disable, order is important
$enable_dns     || iptables  -t mangle -I TPROXY_OUT -p udp --dport 53 -j RETURN
$enable_dns     || ip6tables -t mangle -I TPROXY_OUT -p udp --dport 53 -j RETURN
$enable_udp     || iptables  -t mangle -I TPROXY_OUT -p udp -j RETURN
$enable_udp     || ip6tables -t mangle -I TPROXY_OUT -p udp -j RETURN
$enable_tcp     || iptables  -t mangle -I TPROXY_OUT -p tcp -j RETURN
$enable_tcp     || ip6tables -t mangle -I TPROXY_OUT -p tcp -j RETURN
$enable_ipv4    || iptables  -t mangle -I TPROXY_OUT -j RETURN
$enable_ipv6    || ip6tables -t mangle -I TPROXY_OUT -j RETURN

if $enable_gateway; then
$enable_dns     || iptables  -t mangle -I TPROXY_PRE -p udp --dport 53 -j RETURN
$enable_dns     || ip6tables -t mangle -I TPROXY_PRE -p udp --dport 53 -j RETURN
$enable_udp     || iptables  -t mangle -I TPROXY_PRE -p udp -j RETURN
$enable_udp     || ip6tables -t mangle -I TPROXY_PRE -p udp -j RETURN
$enable_tcp     || iptables  -t mangle -I TPROXY_PRE -p tcp -j RETURN
$enable_tcp     || ip6tables -t mangle -I TPROXY_PRE -p tcp -j RETURN
$enable_ipv4    || iptables  -t mangle -I TPROXY_PRE -j RETURN
$enable_ipv6    || ip6tables -t mangle -I TPROXY_PRE -j RETURN
fi

## do not handle local device connection through tproxy if gateway is not enabled
$enable_gateway || iptables  -t mangle -I TPROXY_PRE -m addrtype ! --src-type LOCAL -j RETURN
$enable_gateway || ip6tables -t mangle -I TPROXY_PRE -m addrtype ! --src-type LOCAL -j RETURN

## make sure following rules are the first in chain TPROXY_PRE to mark new incoming connection or gateway proxy connection
## so must put at last to insert first
iptables  -t mangle -I TPROXY_PRE -m addrtype ! --src-type LOCAL -m conntrack --ctstate NEW -j CONNMARK --set-mark $mark_newin
ip6tables -t mangle -I TPROXY_PRE -m addrtype ! --src-type LOCAL -m conntrack --ctstate NEW -j CONNMARK --set-mark $mark_newin

# message for user
cat << DOC
iptables: noproxy cgroup: ${cgroup_noproxy[@]}
iptables: proxied cgroup: ${cgroup_proxy[@]}
DOC


if $enable_gateway; then
    iptables  -t nat -A POSTROUTING -m owner ! --socket-exists -j MASQUERADE
    ip6tables -t nat -A POSTROUTING -m owner ! --socket-exists -s fc00::/7 -j MASQUERADE # only masquerade ipv6 private address
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv6.conf.all.forwarding=1
    echo "ipatbles: gateway enabled"
fi
