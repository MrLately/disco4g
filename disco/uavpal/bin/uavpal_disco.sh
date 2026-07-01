#!/bin/sh

delayed_fallback_pid_file="/tmp/uavpal_delayed_fallback.pid"
startup_guard_file="/tmp/uavpal_starting"

start_delayed_fallback()
{
	if [ -f "$delayed_fallback_pid_file" ]; then
		delayed_fallback_pid=$(cat "$delayed_fallback_pid_file" 2>/dev/null)
		if [ -n "$delayed_fallback_pid" ] && kill -0 "$delayed_fallback_pid" 2>/dev/null; then
			exit 0
		fi
		rm -f "$delayed_fallback_pid_file"
	fi

	(
		. /data/ftp/uavpal/bin/uavpal_globalfunctions.sh

		delayed_fallback_elapsed=0
		while [ "$delayed_fallback_elapsed" -lt "24" ]
		do
			sleep 2
			delayed_fallback_elapsed=$(($delayed_fallback_elapsed + 2))

			if [ -f /tmp/modem_profile ] && ps | grep -q "[z]erotier-one"; then
				rm -f "$delayed_fallback_pid_file"
				exit 0
			fi

			if [ -f /tmp/uavpal_starting ]; then
				delayed_fallback_starting_pid=$(cat /tmp/uavpal_starting 2>/dev/null)
				if [ -n "$delayed_fallback_starting_pid" ] && kill -0 "$delayed_fallback_starting_pid" 2>/dev/null; then
					rm -f "$delayed_fallback_pid_file"
					exit 0
				fi
				rm -f /tmp/uavpal_starting
			fi

			delayed_fallback_usb_id=$(detect_allowed_modem_usb_id)
			if [ "$delayed_fallback_usb_id" != "" ]; then
				ulogger -s -t uavpal_drone "... delayed USB fallback detected supported modem (${delayed_fallback_usb_id}); starting modem stack"
				/usr/bin/flock -n /tmp/lock/uavpal_disco /data/ftp/uavpal/bin/uavpal_disco.sh
				rm -f "$delayed_fallback_pid_file"
				exit 0
			fi
		done

		rm -f "$delayed_fallback_pid_file"
	) >/dev/null 2>&1 &
	echo "$!" >"$delayed_fallback_pid_file"
	exit 0
}

if [ "$1" = "--delayed-fallback" ]; then
	start_delayed_fallback
fi

if [ -f "$startup_guard_file" ]; then
	startup_guard_pid=$(cat "$startup_guard_file" 2>/dev/null)
	if [ -n "$startup_guard_pid" ] && kill -0 "$startup_guard_pid" 2>/dev/null; then
		ulogger -s -t uavpal_drone "... modem startup already in progress (pid ${startup_guard_pid}), ignoring duplicate USB add event"
		exit 0
	fi
	rm -f "$startup_guard_file"
fi
echo "$$" >"$startup_guard_file"

{
trap 'rm -f /tmp/uavpal_starting' EXIT
# exports
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/data/ftp/uavpal/lib

# variables
cdc_if="eth1"
# TODO: make the following dynamic if possible
ppp_if="ppp0"
# TODO: make the following two dynamic (e.g. via AT^NDISDUP=1,0)
serial_ctrl_dev="ttyUSB0"
serial_ppp_dev="ttyUSB1"

# functions
. /data/ftp/uavpal/bin/uavpal_globalfunctions.sh

start_zerotier_join_loop()
{
	zt_join_pid_file="/tmp/uavpal_zerotier_join.pid"
	if [ -f "$zt_join_pid_file" ]; then
		zt_join_pid=$(cat "$zt_join_pid_file" 2>/dev/null)
		if [ -n "$zt_join_pid" ] && kill -0 "$zt_join_pid" 2>/dev/null; then
			return 0
		fi
		rm -f "$zt_join_pid_file"
	fi

	(
		for i in $(seq 1 60); do
			ztjoin_response=$(/data/ftp/uavpal/bin/zerotier-one -q join "$(conf_read zt_networkid)" 2>&1)
			if [ "$(echo "$ztjoin_response" | head -n1 | awk '{print $1}')" == "200" ]; then
				ulogger -s -t uavpal_drone "... successfully joined zerotier network ID $(conf_read zt_networkid)"
				rm -f "$zt_join_pid_file"
				exit 0
			fi
			ulogger -s -t uavpal_drone "... ERROR joining zerotier network ID $(conf_read zt_networkid): $ztjoin_response - trying again"
			sleep 2
		done
		rm -f "$zt_join_pid_file"
	) >/dev/null 2>&1 &
	echo "$!" >"$zt_join_pid_file"
}

zerotier_network_ready()
{
	zt_ready_nwid="$(conf_read zt_networkid)"
	zt_ready_line=$(/data/ftp/uavpal/bin/zerotier-one -q listnetworks 2>/dev/null | awk -v nwid="$zt_ready_nwid" '$3==nwid { print; exit }')
	if [ -z "$zt_ready_line" ]; then
		return 1
	fi
	zt_ready_state=$(echo "$zt_ready_line" | awk '{ for (i=1; i<=NF; i++) if ($i=="OK" || $i=="ACCESS_DENIED" || $i=="REQUESTING_CONFIGURATION" || $i=="NOT_FOUND" || $i=="PORT_ERROR") { print $i; exit } }')
	zt_ready_ip=$(echo "$zt_ready_line" | awk '{ for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) { gsub(/,.*/, "", $i); print $i; exit } }')
	if [ "$zt_ready_state" = "OK" ] && [ -n "$zt_ready_ip" ]; then
		return 0
	fi
	return 1
}

start_zerotier_ready_loop()
{
	zt_ready_pid_file="/tmp/uavpal_zerotier_ready.pid"
	if [ -f "$zt_ready_pid_file" ]; then
		zt_ready_pid=$(cat "$zt_ready_pid_file" 2>/dev/null)
		if [ -n "$zt_ready_pid" ] && kill -0 "$zt_ready_pid" 2>/dev/null; then
			return 0
		fi
		rm -f "$zt_ready_pid_file"
	fi

	(
		zt_restart_done=0
		for zt_ready_attempt in $(seq 1 30); do
			if zerotier_network_ready; then
				ulogger -s -t uavpal_drone "... zerotier network is ready"
				rm -f "$zt_ready_pid_file"
				exit 0
			fi
			if [ "$zt_ready_attempt" -eq "2" ] || [ $(($zt_ready_attempt % 4)) -eq "0" ]; then
				ulogger -s -t uavpal_drone "... zerotier not ready after Internet-up; nudging network join (attempt ${zt_ready_attempt})"
				/data/ftp/uavpal/bin/zerotier-one -q join "$(conf_read zt_networkid)" >/dev/null 2>&1
			fi
			if [ "$zt_ready_attempt" -ge "8" ] && [ "$zt_restart_done" -eq "0" ] && ! zerotier_network_ready; then
				ulogger -s -t uavpal_drone "... zerotier still not ready; restarting daemon once"
				killall -9 zerotier-one >/dev/null 2>&1
				sleep 2
				/data/ftp/uavpal/bin/zerotier-one -d
				zt_restart_done=1
			fi
			sleep 2
		done
		rm -f "$zt_ready_pid_file"
	) >/dev/null 2>&1 &
	echo "$!" >"$zt_ready_pid_file"
}

start_zerotier_transport()
{
	if [ -d "/data/lib/zerotier-one/networks.d" ] && [ ! -f "/data/lib/zerotier-one/networks.d/$(conf_read zt_networkid).conf" ]; then
		ulogger -s -t uavpal_drone "... zerotier config's network ID does not match zt_networkid config - removing zerotier data directory to allow join of new network ID"
		rm -rf /data/lib/zerotier-one 2>/dev/null
		mkdir -p /data/lib/zerotier-one
		ln -s /data/ftp/uavpal/conf/local.conf /data/lib/zerotier-one/local.conf
	fi

	if ps | grep -q "[z]erotier-one"; then
		ulogger -s -t uavpal_drone "... zerotier daemon already running"
	else
		ulogger -s -t uavpal_drone "... starting zerotier daemon"
		/data/ftp/uavpal/bin/zerotier-one -d
	fi

	if [ ! -d "/data/lib/zerotier-one/networks.d" ]; then
		ulogger -s -t uavpal_drone "... (initial-)joining zerotier network ID $(conf_read zt_networkid)"
		start_zerotier_join_loop
	fi
	start_zerotier_ready_loop
}

# main
modem_usb_id=$(detect_allowed_modem_usb_id)
if [ "$modem_usb_id" == "" ]; then
	ulogger -s -t uavpal_drone "... no supported USB modem found"
	exit 0
fi
modem_vendor=$(echo "$modem_usb_id" | cut -d ':' -f 1)
modem_provider=$(modem_provider_from_usb_id "$modem_usb_id")
modem_profile=$(modem_conf_read MODEM_PROFILE "auto")
echo "$modem_usb_id" >/tmp/modem_usb_id
echo "$modem_provider" >/tmp/modem_provider
ulogger -s -t uavpal_drone "USB modem detected (USB ID: ${modem_usb_id}, profile: ${modem_profile})"
ulogger -s -t uavpal_drone "=== Loading uavpal softmod $(head -1 /data/ftp/uavpal/version.txt |tr -d '\r\n' |tr -d '\n') ==="

# set platform, evinrude=Disco, ardrone3=Bebop 2
platform=$(grep 'ro.parrot.build.product' /etc/build.prop | cut -d'=' -f 2)
drone_fw_version=$(grep 'ro.parrot.build.uid' /etc/build.prop | cut -d '-' -f 3)
drone_fw_version_numeric=${drone_fw_version//.}

if [ "$platform" == "evinrude" ]; then
	drone_alias="Parrot Disco"
	if [ "$drone_fw_version_numeric" -ge "170" ]; then
		kernel_mods="1.7.0"
	else
		kernel_mods="1.4.1"
	fi
elif [ "$platform" == "ardrone3" ]; then
	drone_alias="Parrot Bebop 2"
	kernel_mods="4.4.2"
else
	ulogger -s -t uavpal_drone "... current platform ${platform} is not supported by the softmod - exiting!"
	exit 1
fi

ulogger -s -t uavpal_drone "... detected ${drone_alias} (platform ${platform}), firmware version ${drone_fw_version}"
ulogger -s -t uavpal_drone "... trying to use kernel modules compiled for firmware ${kernel_mods}"

ulogger -s -t uavpal_drone "... loading tunnel kernel module (for zerotier)"
insmod /data/ftp/uavpal/mod/${kernel_mods}/tun.ko

ulogger -s -t uavpal_drone "... loading USB modem kernel modules"
insmod /data/ftp/uavpal/mod/${kernel_mods}/usbserial.ko                 # needed for Disco only
insmod /data/ftp/uavpal/mod/${kernel_mods}/usb_wwan.ko
insmod /data/ftp/uavpal/mod/${kernel_mods}/option.ko

ulogger -s -t uavpal_drone "... loading iptables kernel modules (required for security)"
insmod /data/ftp/uavpal/mod/${kernel_mods}/x_tables.ko                  # needed for Disco firmware <=1.4.1 only
insmod /data/ftp/uavpal/mod/${kernel_mods}/ip_tables.ko                 # needed for Disco firmware <=1.4.1 only
insmod /data/ftp/uavpal/mod/${kernel_mods}/iptable_filter.ko            # needed for Disco firmware <=1.4.1 and >=1.7.0 and Bebop 2 firmware >= 4.4.2
insmod /data/ftp/uavpal/mod/${kernel_mods}/xt_tcpudp.ko                 # needed for Disco firmware <=1.4.1 only

if [ "$modem_vendor" == "12d1" ] && [ "$modem_profile" != "generic_ethernet" ]; then
	ulogger -s -t uavpal_drone "... running usb_modeswitch to switch Huawei modem into huawei-new-mode"
	/data/ftp/uavpal/bin/usb_modeswitch -v 12d1 -p `lsusb |grep "ID 12d1" | cut -f 3 -d \:` --huawei-new-mode -s 3
fi

use_generic_ethernet=0
if [ "$modem_profile" == "generic_ethernet" ]; then
	use_generic_ethernet=1
elif [ "$modem_profile" == "auto" ] && [ "$modem_vendor" != "12d1" ]; then
	use_generic_ethernet=1
elif [ "$modem_profile" != "auto" ] && [ "$modem_profile" != "huawei_hilink" ] && [ "$modem_profile" != "huawei_stick" ]; then
	ulogger -s -t uavpal_drone "... modem profile ${modem_profile} is not supported - exiting!"
	exit 1
fi

if [ "$use_generic_ethernet" -eq 1 ] && [ "$modem_vendor" == "2c7c" ]; then
	quectel_prepare "$modem_usb_id"
fi

ulogger -s -t uavpal_drone "... detecting modem type"
generic_ethernet_attempts=0
while true
do
	# -=-=-=-=-= Hi-Link mode =-=-=-=-=-
	if [ "$use_generic_ethernet" -eq 0 ] && [ "$modem_profile" != "huawei_stick" ] && [ -d "/proc/sys/net/ipv4/conf/${cdc_if}" ]; then
		ulogger -s -t uavpal_drone "... detected Huawei USB modem in Hi-Link mode"
		ulogger -s -t uavpal_drone "... unloading Stick Mode kernel modules (not required for Hi-Link firmware)"
		rmmod option
		rmmod usb_wwan
		rmmod usbserial
		ulogger -s -t uavpal_drone "... connecting modem to Internet (Hi-Link)"
		connect_hilink
		echo huawei_hilink >/tmp/modem_profile
		ulogger -s -t uavpal_drone "... enabling Hi-Link DMZ mode (1:1 NAT for better zerotier performance)"
		hilink_api "post" "/api/security/dmz" "<request><DmzStatus>1</DmzStatus><DmzIPAddress>${hilink_ip}</DmzIPAddress></request>"
		ulogger -s -t uavpal_drone "... setting Hi-Link NAT type full cone (better zerotier performance)"
		hilink_api "post" "/api/security/nat" "<request><NATType>1</NATType></request>"
		ulogger -s -t uavpal_drone "... querying Huawei device details via Hi-Link API"
		hilink_dev_info=$(hilink_api "get" "/api/device/information")
		ulogger -s -t uavpal_drone "... model: $(echo "$hilink_dev_info" | xmllint --xpath 'string(//DeviceName)' -), hardware version: $(echo "$hilink_dev_info" | xmllint --xpath 'string(//HardwareVersion)' -)"
		ulogger -s -t uavpal_drone "... software version: $(echo "$hilink_dev_info" | xmllint --xpath 'string(//SoftwareVersion)' -), WebUI version: $(echo "$hilink_dev_info" | xmllint --xpath 'string(//WebUIVersion)' -)"
		firewall ${cdc_if}
		ulogger -s -t uavpal_drone "... starting connection keep-alive handler in background"
		connection_handler_hilink &
		break 1 # break out of while loop
		
	fi
	# -=-=-=-=-= Stick mode =-=-=-=-=-
	if [ "$use_generic_ethernet" -eq 0 ] && [ "$modem_profile" != "huawei_hilink" ] && [ -c "/dev/${serial_ctrl_dev}" ]; then
		ulogger -s -t uavpal_drone "... detected Huawei USB modem in Stick mode"
		ulogger -s -t uavpal_drone "... loading ppp kernel modules"
		insmod /data/ftp/uavpal/mod/${kernel_mods}/crc-ccitt.ko
		insmod /data/ftp/uavpal/mod/${kernel_mods}/slhc.ko
		insmod /data/ftp/uavpal/mod/${kernel_mods}/ppp_generic.ko
		insmod /data/ftp/uavpal/mod/${kernel_mods}/ppp_async.ko
		insmod /data/ftp/uavpal/mod/${kernel_mods}/ppp_deflate.ko
		insmod /data/ftp/uavpal/mod/${kernel_mods}/bsd_comp.ko
		ulogger -s -t uavpal_drone "... connecting modem to Internet (ppp)"
		connect_stick
		echo huawei_stick >/tmp/modem_profile
		ulogger -s -t uavpal_drone "... querying Huawei device details via AT command"
		fhverString=$(at_command "AT\^FHVER" "OK" "1" | grep "FHVER:" | tail -n 1)
		ulogger -s -t uavpal_drone "... model: $(echo "$fhverString" | cut -d " " -f 1 | cut -d "\"" -f 2), hardware version: $(echo "$fhverString" | cut -d "," -f 2 | cut -d "\"" -f 1)"
		ulogger -s -t uavpal_drone "... software version: $(echo "$fhverString" | cut -d " " -f 2 | cut -d "," -f 1)"
		firewall ${ppp_if}
		ulogger -s -t uavpal_drone "... starting connection keep-alive handler in background"
		connection_handler_stick &
		break 1 # break out of while loop
	fi
	# -=-=-=-=-= Generic Ethernet mode =-=-=-=-=-
	if [ "$use_generic_ethernet" -eq 1 ]; then
		modem_eth_if=$(detect_ethernet_iface)
		if [ "$modem_eth_if" != "" ]; then
			ulogger -s -t uavpal_drone "... detected USB modem in generic Ethernet mode on ${modem_eth_if}"
			ulogger -s -t uavpal_drone "... connecting modem to Internet (Ethernet/DHCP)"
			connect_ethernet "$modem_eth_if"
			if [ "$?" -ne "0" ]; then
				ulogger -s -t uavpal_drone "... generic Ethernet setup failed on ${modem_eth_if}, waiting for modem DHCP/link"
				usleep 100000
				continue
			fi
			echo generic_ethernet >/tmp/modem_profile
			firewall ${modem_eth_if}
			ulogger -s -t uavpal_drone "... starting connection keep-alive handler in background"
			connection_handler_ethernet "$modem_eth_if" &
			break 1 # break out of while loop
		fi
		generic_ethernet_attempts=$(($generic_ethernet_attempts + 1))
		if [ "$modem_vendor" == "2c7c" ] && [ -f /tmp/quectel_usbnet_mode ]; then
			quectel_usbnet_mode=$(cat /tmp/quectel_usbnet_mode)
			if [ "$quectel_usbnet_mode" != "1" ]; then
				ulogger -s -t uavpal_drone "... Quectel usbnet mode is ${quectel_usbnet_mode}, not ECM; set AT+QCFG=\"usbnet\",1 and reboot the modem"
				ulogger -s -t uavpal_drone "... no Ethernet modem interface detected - exiting!"
				exit 1
			fi
		fi
		if [ "$generic_ethernet_attempts" -ge 6 ]; then
			ulogger -s -t uavpal_drone "... no Ethernet modem interface detected after 60 seconds - exiting!"
			exit 1
		fi
	fi
	usleep 100000
done

internet_ready=0
check_connection
if [ "$?" -eq "0" ]; then
	internet_ready=1
	ulogger -s -t uavpal_drone "... public Internet connection is up"
else
	ulogger -s -t uavpal_drone "... public Internet check is degraded"
fi

ulogger -s -t uavpal_drone "... setting DNS servers statically (Google Public DNS)"
echo -e 'nameserver 8.8.8.8\nnameserver 8.8.4.4' >/etc/resolv.conf

if [ "$internet_ready" -eq "1" ]; then
	ulogger -s -t uavpal_drone "... setting date/time using ntp"
	ntpd -n -d -q -p 0.debian.pool.ntp.org -p 1.debian.pool.ntp.org -p 2.debian.pool.ntp.org -p 3.debian.pool.ntp.org
fi

if [ -f /data/ftp/uavpal/conf/debug ]; then
	debug_filename="/data/ftp/internal_000/Debug/ulog_debug_$(date +%Y%m%d%H%M%S).log"
	ulogger -s -t uavpal_drone "... Debug mode is enabled - writing debug log to internal storage: $debug_filename"
	kill -9 $(ps |grep ulogcat |grep debugdummy | awk '{ print $1 }')
	ulogcat -u -k -l -F debugdummy >$debug_filename &
fi

start_zerotier_transport

ulogger -s -t uavpal_drone "... starting Glympse script for GPS tracking"
/data/ftp/uavpal/bin/uavpal_glympse.sh &

ulogger -s -t uavpal_drone "*** idle on LTE ***"
} &
uavpal_main_pid=$!
echo "$uavpal_main_pid" >"$startup_guard_file"
exit 0
