#!/bin/sh
delayed_fallback_pid_file="/tmp/uavpal_delayed_fallback.pid"

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
		load_modem_config

		delayed_fallback_elapsed=0
		while [ "$delayed_fallback_elapsed" -lt "24" ]
		do
			sleep 2
			delayed_fallback_elapsed=$((delayed_fallback_elapsed + 2))

			if [ -f /tmp/modem_connection_profile ] && ps | grep -q "[z]erotier-one"; then
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

			if detect_usb_modem; then
				ulogger -s -t uavpal_drone "... delayed USB fallback detected configured modem (${matched_usb_id}); starting modem stack"
				/usr/bin/flock -n /tmp/lock/uavpal_disco /data/ftp/uavpal/bin/uavpal_disco.sh
				rm -f "$delayed_fallback_pid_file"
				exit 0
			fi
		done

		rm -f "$delayed_fallback_pid_file"
	) >/dev/null 2>&1 &
	echo "$!" > "$delayed_fallback_pid_file"
	exit 0
}

if [ "$1" = "--delayed-fallback" ]; then
	start_delayed_fallback
fi

startup_guard_file="/tmp/uavpal_starting"
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
# exports
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/data/ftp/uavpal/lib

# variables
cdc_if="eth1"
ppp_if="ppp0"
serial_ctrl_dev="ttyUSB0"
serial_ppp_dev="ttyUSB1"
connection_profile=""
connection_handler_type=""
ppp_modules_loaded=0
modem_detect_timeout=300
internet_wait_timeout=300

trap 'rm -f /tmp/uavpal_starting' EXIT
rm -f /tmp/uavpal_queue_diag /tmp/uavpal_route_diag /tmp/uavpal_reconnect_diag
rm -f /tmp/modem_provider /tmp/uavpal_quectel_setup_diag

# functions
. /data/ftp/uavpal/bin/uavpal_globalfunctions.sh
load_modem_config

load_ppp_modules()
{
	if [ "$ppp_modules_loaded" -eq "1" ]; then
		return
	fi
	ulogger -s -t uavpal_drone "... loading ppp kernel modules"
	insmod /data/ftp/uavpal/mod/${kernel_mods}/crc-ccitt.ko
	insmod /data/ftp/uavpal/mod/${kernel_mods}/slhc.ko
	insmod /data/ftp/uavpal/mod/${kernel_mods}/ppp_generic.ko
	insmod /data/ftp/uavpal/mod/${kernel_mods}/ppp_async.ko
	insmod /data/ftp/uavpal/mod/${kernel_mods}/ppp_deflate.ko
	insmod /data/ftp/uavpal/mod/${kernel_mods}/bsd_comp.ko
	ppp_modules_loaded=1
}

connect_stick_auto_ports()
{
	connect_stick
	if [ "$?" -eq "0" ]; then
		return 0
	fi

	if [ "$MODEM_SERIAL_CTRL" = "auto" ] && [ "$MODEM_SERIAL_PPP" = "auto" ] && [ "${serial_dev_count:-0}" -ge "2" ]; then
		ulogger -s -t uavpal_drone "... PPP setup failed, retrying with swapped serial ports (ctrl=${serial_ppp_dev}, ppp=${serial_ctrl_dev})"
		swap_tmp="$serial_ctrl_dev"
		serial_ctrl_dev="$serial_ppp_dev"
		serial_ppp_dev="$swap_tmp"
		connect_stick
		return $?
	fi

	return 1
}

configure_hilink_features()
{
	echo "$modem_gateway_ip" >/tmp/hilink_router_ip
	hilink_ip="$modem_ip"

	hilink_profiles=$(hilink_api "get" "/api/dialup/profiles")
	hilink_apn_index=$(echo "$hilink_profiles" | xmllint --xpath "string(//CurrentProfile)" - 2>/dev/null)
	hilink_apn=$(echo "$hilink_profiles" | xmllint --xpath "string(//Profile[${hilink_apn_index}]/ApnName)" - 2>/dev/null)
	if [ -n "$hilink_apn" ]; then
		ulogger -s -t uavpal_drone "... connecting to mobile network using APN \"${hilink_apn}\" (configured in the modem Web UI)"
	fi

	if [ "$MODEM_HILINK_DMZ" = "1" ]; then
		ulogger -s -t uavpal_drone "... enabling Hi-Link DMZ mode (1:1 NAT for better zerotier performance)"
		hilink_api "post" "/api/security/dmz" "<request><DmzStatus>1</DmzStatus><DmzIPAddress>${hilink_ip}</DmzIPAddress></request>"
	fi
	if [ "$MODEM_HILINK_FULLCONE_NAT" = "1" ]; then
		ulogger -s -t uavpal_drone "... setting Hi-Link NAT type full cone (better zerotier performance)"
		hilink_api "post" "/api/security/nat" "<request><NATType>1</NATType></request>"
	fi

	hilink_dev_info=$(hilink_api "get" "/api/device/information")
	ulogger -s -t uavpal_drone "... model: $(echo "$hilink_dev_info" | xmllint --xpath 'string(//DeviceName)' -), hardware version: $(echo "$hilink_dev_info" | xmllint --xpath 'string(//HardwareVersion)' -)"
	ulogger -s -t uavpal_drone "... software version: $(echo "$hilink_dev_info" | xmllint --xpath 'string(//SoftwareVersion)' -), WebUI version: $(echo "$hilink_dev_info" | xmllint --xpath 'string(//WebUIVersion)' -)"
}

start_zerotier_join_loop()
{
	zt_join_pid_file="/tmp/uavpal_zerotier_join.pid"

	if [ -f "$zt_join_pid_file" ]; then
		old_pid=$(cat "$zt_join_pid_file" 2>/dev/null)
		if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
			return 0
		fi
		rm -f "$zt_join_pid_file"
	fi

	(
		zt_join_attempt=0
		while true
		do
			zt_join_attempt=$((zt_join_attempt + 1))
			ztjoin_response=$(/data/ftp/uavpal/bin/zerotier-one -q join "$(conf_read zt_networkid)" 2>&1)
			if [ "$(echo "$ztjoin_response" | head -n 1 | awk '{print $1}')" = "200" ]; then
				ulogger -s -t uavpal_drone "... successfully joined zerotier network ID $(conf_read zt_networkid)"
				rm -f "$zt_join_pid_file"
				break
			fi
			if [ "$zt_join_attempt" -eq "1" ] || [ $((zt_join_attempt % 10)) -eq "0" ]; then
				ulogger -s -t uavpal_drone "... ERROR joining zerotier network ID $(conf_read zt_networkid): $ztjoin_response - trying again"
			fi
			sleep 1
		done
	) >/dev/null 2>&1 &
	echo "$!" > "$zt_join_pid_file"
}

zerotier_network_ready()
{
	zt_info_state=$(/data/ftp/uavpal/bin/zerotier-one -q info 2>/dev/null | awk '{ print $5; exit }')
	if [ "$zt_info_state" != "ONLINE" ]; then
		return 1
	fi

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
		old_pid=$(cat "$zt_ready_pid_file" 2>/dev/null)
		if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
			return 0
		fi
		rm -f "$zt_ready_pid_file"
	fi

	(
		zt_ready_attempt=0
		zt_restart_done=0
		while true
		do
			if zerotier_network_ready; then
				ulogger -s -t uavpal_drone "... zerotier network is ready"
				rm -f "$zt_ready_pid_file"
				exit 0
			fi

			check_connection
			if [ "$?" -eq "0" ]; then
				zt_ready_attempt=$((zt_ready_attempt + 1))
				if [ "$zt_ready_attempt" -eq "1" ] || [ $((zt_ready_attempt % 6)) -eq "0" ]; then
					ulogger -s -t uavpal_drone "... zerotier not ready after Internet-up; nudging network join (attempt ${zt_ready_attempt})"
				fi
				/data/ftp/uavpal/bin/zerotier-one -q join "$(conf_read zt_networkid)" >/dev/null 2>&1

				if [ "$zt_ready_attempt" -ge "4" ] && [ "$zt_restart_done" -eq "0" ] && ! zerotier_network_ready; then
					ulogger -s -t uavpal_drone "... zerotier still not ready; restarting daemon once"
					killall -9 zerotier-one >/dev/null 2>&1
					sleep 1
					/data/ftp/uavpal/bin/zerotier-one -d
					zt_restart_done=1
				fi
			fi
			sleep 5
		done
	) >/dev/null 2>&1 &
	echo "$!" > "$zt_ready_pid_file"
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

start_connection_keepalive_handler()
{
	if [ -z "$connection_handler_type" ]; then
		return 0
	fi

	ulogger -s -t uavpal_drone "... starting connection keep-alive handler in background"
	case "$connection_handler_type" in
	hilink)
		connection_handler_hilink &
		;;
	ethernet)
		connection_handler_ethernet &
		;;
	stick)
		connection_handler_stick &
		;;
	*)
		ulogger -s -t uavpal_drone "... WARNING: unknown connection handler type '${connection_handler_type}'"
		;;
	esac
}

start_glympse()
{
	if ps | grep -q "[u]avpal_glympse.sh"; then
		return 0
	fi
	ulogger -s -t uavpal_drone "... starting Glympse script for GPS tracking"
	/data/ftp/uavpal/bin/uavpal_glympse.sh &
}

start_online_services()
{
	start_connection_keepalive_handler
	start_glympse
}

start_online_services_when_internet_ready()
{
	connection_wait_pid_file="/tmp/uavpal_connection_wait.pid"

	if [ -f "$connection_wait_pid_file" ]; then
		old_pid=$(cat "$connection_wait_pid_file" 2>/dev/null)
		if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
			return 0
		fi
		rm -f "$connection_wait_pid_file"
	fi

	(
		connection_wait_started=$(date +%s)
		while true; do
			check_connection
			if [ "$?" -eq "0" ]; then
				ulogger -s -t uavpal_drone "... public Internet connection is up"
				rm -f "$connection_wait_pid_file"
				start_online_services
				exit 0
			fi
			if [ $(( $(date +%s) - connection_wait_started )) -ge $internet_wait_timeout ]; then
				ulogger -s -t uavpal_drone "... public Internet check is degraded; online services still waiting"
				connection_wait_started=$(date +%s)
			fi
			sleep 5
		done
	) >/dev/null 2>&1 &
	echo "$!" > "$connection_wait_pid_file"
}

cleanup_startup_failure()
{
	ulogger -s -t uavpal_drone "... startup failed, cleaning partial modem state"
	rm -f /tmp/modem_connection_profile
	killall -9 udhcpc >/dev/null 2>&1
	killall -9 pppd >/dev/null 2>&1
	killall -9 chat >/dev/null 2>&1

	if [ -f /tmp/hilink_router_ip ]; then
		ip route del default via "$(cat /tmp/hilink_router_ip)" dev "${cdc_if}" >/dev/null 2>&1
	fi
	if [ -f /tmp/modem_gateway_ip ]; then
		ip route del default via "$(cat /tmp/modem_gateway_ip)" dev "${cdc_if}" >/dev/null 2>&1
	fi
	ip route del default dev "${ppp_if}" >/dev/null 2>&1

	rm -f /tmp/hilink_router_ip /tmp/hilink_login_required /tmp/modem_gateway_ip /tmp/modem_ip /tmp/modem_iface /tmp/modem_usb_id /tmp/modem_usb_desc /tmp/modem_provider /tmp/serial_ctrl_dev
	rm -f /tmp/uavpal_quectel_setup_diag
}

# main
if ! detect_usb_modem; then
	ulogger -s -t uavpal_drone "... USB event detected, but no configured modem USB ID matched (${MODEM_USB_IDS}) - exiting"
	exit 0
fi

if [ -f /tmp/modem_connection_profile ]; then
	if ps | grep -q "[z]erotier-one"; then
		ulogger -s -t uavpal_drone "... modem connection already active ($(cat /tmp/modem_connection_profile)), ignoring duplicate USB add event"
		exit 0
	fi
	rm -f /tmp/modem_connection_profile
	rm -f /tmp/modem_provider
fi

ulogger -s -t uavpal_drone "USB modem detected (USB ID: ${matched_usb_id}${matched_usb_desc:+, device: ${matched_usb_desc}})"
echo "${matched_usb_id}" >/tmp/modem_usb_id
echo "${matched_usb_desc}" >/tmp/modem_usb_desc
ulogger -s -t uavpal_drone "=== Loading uavpal softmod $(head -1 /data/ftp/uavpal/version.txt |tr -d '\r\n' |tr -d '\n') ==="

# set platform, evinrude=Disco, ardrone3=Bebop 2
platform=$(grep 'ro.parrot.build.product' /etc/build.prop | cut -d'=' -f 2)
drone_fw_version=$(grep 'ro.parrot.build.uid' /etc/build.prop | cut -d '-' -f 3)
drone_fw_version_numeric=${drone_fw_version//.}

if [ "$platform" = "evinrude" ]; then
	drone_alias="Parrot Disco"
	if [ "$drone_fw_version_numeric" -ge "170" ]; then
		kernel_mods="1.7.0"
	else
		kernel_mods="1.4.1"
	fi
elif [ "$platform" = "ardrone3" ]; then
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
insmod /data/ftp/uavpal/mod/${kernel_mods}/usbserial.ko
insmod /data/ftp/uavpal/mod/${kernel_mods}/usb_wwan.ko
insmod /data/ftp/uavpal/mod/${kernel_mods}/option.ko

ulogger -s -t uavpal_drone "... loading iptables kernel modules (required for security)"
insmod /data/ftp/uavpal/mod/${kernel_mods}/x_tables.ko
insmod /data/ftp/uavpal/mod/${kernel_mods}/ip_tables.ko
insmod /data/ftp/uavpal/mod/${kernel_mods}/iptable_filter.ko
insmod /data/ftp/uavpal/mod/${kernel_mods}/xt_tcpudp.ko

run_usb_modeswitch
sleep 1
detect_usb_modem
if [ -n "$matched_usb_id" ]; then
	echo "${matched_usb_id}" >/tmp/modem_usb_id
	echo "${matched_usb_desc}" >/tmp/modem_usb_desc
fi

if is_quectel_ecm_modem; then
	echo "quectel_ecm" >/tmp/modem_provider
	quectel_bind_option_driver >/dev/null 2>&1
	if ! quectel_require_ecm; then
		cleanup_startup_failure
		exit 1
	fi
fi

ulogger -s -t uavpal_drone "... detecting modem profile"
modem_detect_started=$(date +%s)
while true
do
	detect_cdc_iface
	cdc_detected=$?
	detect_serial_devices
	serial_detected=$?

	mode_profile="$MODEM_PROFILE"
	if [ -z "$mode_profile" ]; then
		mode_profile="auto"
	fi

	if [ "$mode_profile" = "huawei_hilink" ]; then
		if [ "$cdc_detected" -eq "0" ]; then
			ulogger -s -t uavpal_drone "... connecting modem to Internet (forced profile: huawei_hilink, iface ${cdc_if})"
			connect_ethernet
			if [ "$?" -ne "0" ]; then
				ulogger -s -t uavpal_drone "... forced huawei_hilink profile failed to obtain Ethernet link"
				usleep 100000
				continue
			fi
			if modem_has_hilink_api; then
				connection_profile="huawei_hilink"
				configure_hilink_features
				firewall ${cdc_if}
				connection_handler_type="hilink"
				break 1
			fi
		fi
		usleep 100000
		continue
	fi

	if [ "$mode_profile" = "generic_ethernet" ]; then
		if [ "$cdc_detected" -eq "0" ]; then
			ulogger -s -t uavpal_drone "... connecting modem to Internet (forced profile: generic_ethernet, iface ${cdc_if})"
			connect_ethernet
			if [ "$?" -ne "0" ]; then
				ulogger -s -t uavpal_drone "... forced generic_ethernet profile failed to obtain Ethernet link"
				usleep 100000
				continue
			fi
			connection_profile="generic_ethernet"
			rm -f /tmp/hilink_router_ip /tmp/hilink_login_required
			if ! is_quectel_ecm_modem; then
				rm -f /tmp/serial_ctrl_dev
			fi
			firewall ${cdc_if}
			connection_handler_type="ethernet"
			break 1
		fi
		usleep 100000
		continue
	fi

	if [ "$mode_profile" = "huawei_stick" ]; then
		if [ "$serial_detected" -eq "0" ] && [ -c "/dev/${serial_ctrl_dev}" ]; then
			ulogger -s -t uavpal_drone "... connecting modem to Internet (forced profile: huawei_stick, serial ${serial_ppp_dev})"
			load_ppp_modules
			connect_stick_auto_ports
			if [ "$?" -ne "0" ]; then
				ulogger -s -t uavpal_drone "... forced huawei_stick profile failed to establish PPP link"
				usleep 100000
				continue
			fi
			ulogger -s -t uavpal_drone "... querying Huawei device details via AT command"
			fhverString=$(at_command "AT\^FHVER" "OK" "1" | grep "FHVER:" | tail -n 1)
			ulogger -s -t uavpal_drone "... model: $(echo "$fhverString" | cut -d " " -f 1 | cut -d "\"" -f 2), hardware version: $(echo "$fhverString" | cut -d "," -f 2 | cut -d "\"" -f 1)"
			ulogger -s -t uavpal_drone "... software version: $(echo "$fhverString" | cut -d " " -f 2 | cut -d "," -f 1)"
			connection_profile="huawei_stick"
			rm -f /tmp/hilink_router_ip /tmp/hilink_login_required
			firewall ${ppp_if}
			connection_handler_type="stick"
			break 1
		fi
		usleep 100000
		continue
	fi

	if [ "$mode_profile" = "generic_ppp" ]; then
		if [ "$serial_detected" -eq "0" ] && [ -c "/dev/${serial_ctrl_dev}" ]; then
			ulogger -s -t uavpal_drone "... connecting modem to Internet (forced profile: generic_ppp, serial ${serial_ppp_dev})"
			load_ppp_modules
			connect_stick_auto_ports
			if [ "$?" -ne "0" ]; then
				ulogger -s -t uavpal_drone "... forced generic_ppp profile failed to establish PPP link"
				usleep 100000
				continue
			fi
			connection_profile="generic_ppp"
			rm -f /tmp/hilink_router_ip /tmp/hilink_login_required
			firewall ${ppp_if}
			connection_handler_type="stick"
			break 1
		fi
		usleep 100000
		continue
	fi

	if [ "$cdc_detected" -eq "0" ]; then
		ulogger -s -t uavpal_drone "... detected modem network interface ${cdc_if}, trying Ethernet mode"
		connect_ethernet
		if [ "$?" -ne "0" ]; then
			ulogger -s -t uavpal_drone "... Ethernet mode failed on ${cdc_if}, trying PPP/serial fallback"
		elif modem_has_hilink_api; then
			ulogger -s -t uavpal_drone "... detected modem with Hi-Link compatible API"
			ulogger -s -t uavpal_drone "... unloading Stick Mode kernel modules (not required in Hi-Link/Ethernet mode)"
			rmmod option >/dev/null 2>&1
			rmmod usb_wwan >/dev/null 2>&1
			rmmod usbserial >/dev/null 2>&1
			connection_profile="huawei_hilink"
			configure_hilink_features
			firewall ${cdc_if}
			connection_handler_type="hilink"
			break 1
		else
			ulogger -s -t uavpal_drone "... detected generic USB Ethernet modem (no Hi-Link API)"
			connection_profile="generic_ethernet"
			rm -f /tmp/hilink_router_ip /tmp/hilink_login_required
			if ! is_quectel_ecm_modem; then
				rm -f /tmp/serial_ctrl_dev
			fi
			firewall ${cdc_if}
			connection_handler_type="ethernet"
			break 1
		fi
	fi

	if [ "$serial_detected" -eq "0" ] && [ -c "/dev/${serial_ctrl_dev}" ]; then
		ulogger -s -t uavpal_drone "... detected modem serial interface /dev/${serial_ctrl_dev}, trying PPP mode"
		load_ppp_modules
		connect_stick_auto_ports
		if [ "$?" -ne "0" ]; then
			ulogger -s -t uavpal_drone "... PPP setup failed on auto profile, waiting for next modem state"
			usleep 100000
			continue
		fi
		if [ "$matched_usb_vendor" = "12d1" ]; then
			ulogger -s -t uavpal_drone "... querying Huawei device details via AT command"
			fhverString=$(at_command "AT\^FHVER" "OK" "1" | grep "FHVER:" | tail -n 1)
			ulogger -s -t uavpal_drone "... model: $(echo "$fhverString" | cut -d " " -f 1 | cut -d "\"" -f 2), hardware version: $(echo "$fhverString" | cut -d "," -f 2 | cut -d "\"" -f 1)"
			ulogger -s -t uavpal_drone "... software version: $(echo "$fhverString" | cut -d " " -f 2 | cut -d "," -f 1)"
			connection_profile="huawei_stick"
		else
			connection_profile="generic_ppp"
		fi
		rm -f /tmp/hilink_router_ip /tmp/hilink_login_required
		firewall ${ppp_if}
		connection_handler_type="stick"
		break 1
	fi

	if [ $(( $(date +%s) - modem_detect_started )) -ge $modem_detect_timeout ]; then
		ulogger -s -t uavpal_drone "... ERROR: timeout while detecting/initializing modem profile"
		cleanup_startup_failure
		exit 1
	fi
	usleep 100000
done

echo "${connection_profile}" >/tmp/modem_connection_profile
ulogger -s -t uavpal_drone "... active modem profile: ${connection_profile}"

start_zerotier_transport

internet_ready=0
check_connection
if [ "$?" -eq "0" ]; then
	internet_ready=1
fi
if [ "$internet_ready" -eq "1" ]; then
	ulogger -s -t uavpal_drone "... public Internet connection is up"
else
	ulogger -s -t uavpal_drone "... public Internet check is degraded"
fi

if [ "$internet_ready" -eq "1" ]; then
	start_online_services
else
	ulogger -s -t uavpal_drone "... online services deferred until public Internet is confirmed"
	start_online_services_when_internet_ready
fi

ulogger -s -t uavpal_drone "... setting DNS servers statically (Google Public DNS)"
echo -e 'nameserver 8.8.8.8\nnameserver 8.8.4.4' >/etc/resolv.conf

if [ "$internet_ready" -eq "1" ]; then
	ulogger -s -t uavpal_drone "... setting date/time using ntp"
	ntpd -n -d -q -p 0.debian.pool.ntp.org -p 1.debian.pool.ntp.org -p 2.debian.pool.ntp.org -p 3.debian.pool.ntp.org
else
	ulogger -s -t uavpal_drone "... skipping ntp while public Internet check is degraded"
fi

if [ -f /data/ftp/uavpal/conf/debug ]; then
	debug_filename="/data/ftp/internal_000/Debug/ulog_debug_$(date +%Y%m%d%H%M%S).log"
	ulogger -s -t uavpal_drone "... Debug mode is enabled - writing debug log to internal storage: $debug_filename"
	kill -9 $(ps |grep ulogcat |grep debugdummy | awk '{ print $1 }')
	ulogcat -u -k -l -F debugdummy >$debug_filename &
fi

ulogger -s -t uavpal_drone "*** idle on LTE ***"
}
uavpal_main_pid=$!
echo "$uavpal_main_pid" >"$startup_guard_file"
exit 0
