hilink_api()
{
# Usage: hilink_api {get,post} url-context [json-data]
# Note: callers invoking this function using method "post" do not need to process (echoed) return values, as errors are outputted within the function itself, otherwise the response is <response>OK</response>
#       callers invoking this function using method "get" should handle (echoed) return values using var=$(hilink_api)

	if [ "$1" == "post" ]; then
		method="POST"
	else
		method="GET"
	fi
	url="$2"
	data="$3"

	hilink_router_ip=$(cat /tmp/hilink_router_ip)
	sessionInfo=$(/data/ftp/uavpal/bin/curl -s -X GET "http://${hilink_router_ip}/api/webserver/SesTokInfo" 2>/dev/null)
	if [ "$?" -ne "0" ]; then ulogger -s -t uavpal_hilink_api "... Error connecting to Hi-Link API"; fi
	cookie=$(echo "$sessionInfo" | grep "SessionID=" | cut -b 10-147)
	token=$(echo "$sessionInfo" | grep "TokInfo" | cut -b 10-41)
	if [ -f /tmp/hilink_login_required ]; then
		sessionInfoLogin=$(/data/ftp/uavpal/bin/curl -s -X POST "http://${hilink_router_ip}/api/user/login" -d "<request><Username>admin</Username><Password>$(echo -n "admin" |base64)</Password><password_type>3</password_type></request>" -H "Cookie: $cookie" -H "__RequestVerificationToken: $token" --dump-header - 2>/dev/null)
		if echo -n "$sessionInfoLogin" | grep '<code>108006\|<code>108007' ; then
			ulogger -s -t uavpal_hilink_api "... Hi-Link authentication error. Please disable password protection or set it to user=admin, password=admin"
			return # break out function
		fi
		cookie=$(echo -n "$sessionInfoLogin" | grep "SessionID=" | cut -d ':' -f2 | cut -d ';' -f1)
		token=$(echo -n "$sessionInfoLogin" | grep "__RequestVerificationTokenone" | cut -d ':' -f2)
		sessionInfoAdm=$(curl -s -X GET "http://${hilink_router_ip}/api/webserver/SesTokInfo" -H "Cookie: $cookie" 2>/dev/null)
		token=$(echo "$sessionInfoAdm" | grep "TokInfo" | cut -b 10-41)
	fi
	result=$(/data/ftp/uavpal/bin/curl -s -X $method "http://${hilink_router_ip}${url}" -d "$data" -H "Cookie: $cookie" -H "__RequestVerificationToken: $token" 2>/dev/null)
	if echo "$result" | grep "<error>" ; then
		if [ "$(echo $result | xmllint --xpath 'string(//error/code)' -)" -eq "100003" ]; then
			ulogger -s -t uavpal_hilink_api "... Hi-Link authentication required. Trying to login using user=admin, password=admin"
			touch /tmp/hilink_login_required
			result=$(hilink_api "$1" "$2" "$3")
		else
			ulogger -s -t uavpal_hilink_api "... Hi-Link returned Error Code: $(echo $result | xmllint --xpath 'string(//error/code)' -)"
		fi
	fi
	echo "$result"
}

firewall()
{
	# Security: block incoming connections on the Internet interface
	# these connections should only be allowed on Wi-Fi (eth0) and via zerotier (zt*)
	ulogger -s -t uavpal_drone "... applying iptables security rules for interface ${1}"
	ip_block='21 23 51 61 873 8888 9050 44444 67 5353 14551'
	for i in $ip_block; do iptables -I INPUT -p tcp -i ${1} --dport $i -j DROP; done
}

conf_read()
{
	result=$(head -1 /data/ftp/uavpal/conf/${1})
	echo "$result" |tr -d '\r\n' |tr -d '\n'
}

modem_conf_read()
{
	key="$1"
	default_value="$2"
	conf_file="/data/ftp/uavpal/conf/modem.conf"
	result=""
	if [ -f "$conf_file" ]; then
		result=$(grep "^${key}=" "$conf_file" | tail -n 1 | cut -d '=' -f 2- | cut -d '#' -f 1 | tr -d '\r\n')
	fi
	if [ "$result" == "" ]; then
		result="$default_value"
	fi
	echo "$result"
}

normalize_usb_id()
{
	echo "$1" | cut -d '/' -f 1,2 | tr '/' ':' | tr 'A-F' 'a-f'
}

modem_usb_id_allowed()
{
	usb_id=$(normalize_usb_id "$1")
	usb_vendor=$(echo "$usb_id" | cut -d ':' -f 1)
	usb_product=$(echo "$usb_id" | cut -d ':' -f 2)
	allowed_ids=$(modem_conf_read MODEM_USB_IDS "12d1:*")

	for allowed_id in $allowed_ids; do
		allowed_id=$(normalize_usb_id "$allowed_id")
		allowed_vendor=$(echo "$allowed_id" | cut -d ':' -f 1)
		allowed_product=$(echo "$allowed_id" | cut -d ':' -f 2)
		if [ "$allowed_product" == "$allowed_vendor" ]; then
			allowed_product="*"
		fi
		if [ "$usb_vendor" == "$allowed_vendor" ] && [ "$allowed_product" == "*" -o "$usb_product" == "$allowed_product" ]; then
			return 0
		fi
	done
	return 1
}

detect_allowed_modem_usb_id()
{
	for usb_id in $(lsusb | awk '{ print $6 }'); do
		if modem_usb_id_allowed "$usb_id"; then
			echo "$usb_id"
			return 0
		fi
	done
	return 1
}

modem_provider_from_usb_id()
{
	usb_id=$(normalize_usb_id "$1")
	usb_vendor=$(echo "$usb_id" | cut -d ':' -f 1)
	if [ "$usb_vendor" == "12d1" ]; then
		echo "huawei"
	elif [ "$usb_vendor" == "2c7c" ]; then
		echo "quectel"
	else
		echo "generic"
	fi
}

at_command_dev()
{
	ctrl_dev="$1"
	command="$2"
	expected_response="$3"
	timeout="$4"
	if [ "$ctrl_dev" == "" ] || [ ! -c "/dev/${ctrl_dev}" ]; then
		ulogger -s -t uavpal_at_command "... AT control device ${ctrl_dev} is not available"
		return 1
	fi
	result=$(/data/ftp/uavpal/bin/chat -V -t $timeout '' "$command" "$expected_response" '' > /dev/${ctrl_dev} < /dev/${ctrl_dev}) 2>&1
	if [ "$?" -ne "0" ]; then ulogger -s -t uavpal_at_command "... Did not receive expected output from AT command $command"; fi
	echo "$result"
}

at_command()
{
	at_command_dev "$serial_ctrl_dev" "$1" "$2" "$3"
}

find_quectel_at_port()
{
	for ctrl_dev in ttyUSB2 ttyUSB0 ttyUSB1 ttyUSB3 ttyUSB4 ttyUSB5; do
		if [ -c "/dev/${ctrl_dev}" ]; then
			at_result=$(at_command_dev "$ctrl_dev" "AT" "OK" "1")
			if echo "$at_result" | grep "OK" >/dev/null; then
				echo "$ctrl_dev"
				return 0
			fi
		fi
	done
	return 1
}

quectel_prepare()
{
	usb_id=$(normalize_usb_id "$1")
	usb_vendor=$(echo "$usb_id" | cut -d ':' -f 1)
	usb_product=$(echo "$usb_id" | cut -d ':' -f 2)

	if [ ! -c /dev/ttyUSB0 ]; then
		for option_driver in option1 option; do
			if [ -e /sys/bus/usb-serial/drivers/${option_driver}/new_id ]; then
				ulogger -s -t uavpal_quectel "... binding Quectel ${usb_id} to ${option_driver} driver for AT access"
				(echo "${usb_vendor} ${usb_product}" > /sys/bus/usb-serial/drivers/${option_driver}/new_id) 2>/dev/null
				sleep 1
				break
			fi
		done
	fi

	quectel_ctrl_dev=$(find_quectel_at_port)
	if [ "$quectel_ctrl_dev" == "" ]; then
		ulogger -s -t uavpal_quectel "... Quectel AT port not ready, continuing with Ethernet startup"
		return 0
	fi

	serial_ctrl_dev="$quectel_ctrl_dev"
	echo "$serial_ctrl_dev" >/tmp/serial_ctrl_dev

	quectel_model=$(at_command "AT+GMM" "OK" "1" | grep -v "AT+GMM" | grep -v "OK" | tail -n 1 | tr -d '\r')
	if [ "$quectel_model" != "" ]; then
		ulogger -s -t uavpal_quectel "... model: ${quectel_model}"
	fi

	usbnet_string=$(at_command "AT+QCFG=\"usbnet\"" "OK" "1" | grep "QCFG:" | tail -n 1)
	usbnet_mode=$(echo "$usbnet_string" | cut -d ',' -f 2 | tr -d ' "\r')
	if [ "$usbnet_mode" == "1" ]; then
		echo "$usbnet_mode" >/tmp/quectel_usbnet_mode
		ulogger -s -t uavpal_quectel "... Quectel usbnet mode is ECM"
	elif [ "$usbnet_mode" != "" ]; then
		echo "$usbnet_mode" >/tmp/quectel_usbnet_mode
		ulogger -s -t uavpal_quectel "... Quectel usbnet mode is ${usbnet_mode}; expected 1 for ECM"
	fi

	quectel_network=$(at_command "AT+QNWINFO" "OK" "1" | grep "QNWINFO:" | tail -n 1 | tr -d '\r')
	if [ "$quectel_network" != "" ]; then
		ulogger -s -t uavpal_quectel "... network: ${quectel_network}"
	fi
	quectel_cell=$(at_command "AT+QENG=\"servingcell\"" "OK" "1" | grep "QENG:" | tail -n 1 | tr -d '\r')
	if [ "$quectel_cell" != "" ]; then
		ulogger -s -t uavpal_quectel "... serving cell: ${quectel_cell}"
	fi
}

send_message()
{
	# delay sending of messages if modem is not yet online
	for i in $(seq 0 5); do
		check_connection
	done
	if [ $? -ne 0 ]; then
		ulogger -s -t uavpal_send_message "... Cannot send message (no connection). Exiting send_message function!"
		exit 1 # exit function
	fi
	phone_no="$(conf_read phonenumber)"
	if [ "$phone_no" != "+XXYYYYYYYYY" ]; then
		if [ ! -f "/tmp/hilink_router_ip" ]; then
			if [ "$serial_ctrl_dev" != "" ] && [ -c "/dev/${serial_ctrl_dev}" ]; then
				ulogger -s -t uavpal_send_message "... sending SMS to ${phone_no} (via ${serial_ctrl_dev})"
				at_command "AT+CMGF=1\rAT+CMGS=\"${phone_no}\"\r${1}\32" "OK" "2"
			else
				ulogger -s -t uavpal_send_message "... SMS is not available for the current modem"
			fi
		else
			ulogger -s -t uavpal_send_message "... sending SMS to ${phone_no} (via Hi-Link API)"
			hilink_api "post" "/api/sms/send-sms" "<request><Index>-1</Index><Phones><Phone>${phone_no}</Phone></Phones><Sca></Sca><Content>${1}</Content><Length>-1</Length><Reserved>-1</Reserved><Date>-1</Date></request>"
		fi
	fi
	
	pb_access_token="$(conf_read pushbullet)"
	if [ "$pb_access_token" != "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" ]; then
		ulogger -s -t uavpal_send_message "... sending push notification (via Pushbullet API)"
		/data/ftp/uavpal/bin/curl -q -k -u ${pb_access_token}: -X POST https://api.pushbullet.com/v2/pushes --header 'Content-Type: application/json' --data-binary '{"type": "note", "title": "'"$2"'", "body": "'"$1"'"}'
	fi
}

connect_hilink()
{
	ulogger -s -t uavpal_connect_hilink "... bringing up Hi-Link network interface"
	ifconfig ${cdc_if} up
	ulogger -s -t uavpal_connect_hilink "... requesting IP address from modem's DHCP server"
	hilink_ip=`udhcpc -i ${cdc_if} -n -t 10 2>&1 |grep obtained | awk '{ print $4 }'`
	hilink_router_ip=$(echo `echo $hilink_ip | cut -d '.' -f 1,2,3`.1)
	ulogger -s -t uavpal_connect_hilink "... setting ${cdc_if}'s IP address to $hilink_ip"
	ifconfig ${cdc_if} ${hilink_ip} netmask 255.255.255.0
	ulogger -s -t uavpal_connect_hilink "... setting default route for $hilink_router_ip"
	ip route add default via ${hilink_router_ip} dev ${cdc_if}
	echo $hilink_router_ip >/tmp/hilink_router_ip
	hilink_profiles=$(hilink_api "get" "/api/dialup/profiles")
	hilink_apn_index=$(echo $hilink_profiles | xmllint --xpath "string(//CurrentProfile)" -)
	hilink_apn=$(echo $hilink_profiles | xmllint --xpath "string(//Profile[${hilink_apn_index}]/ApnName)" -)
	ulogger -s -t uavpal_connect_hilink "... connecting to mobile network using APN \"${hilink_apn}\" (configured in the Hi-Link Web UI)"
}

connect_stick()
{
	ulogger -s -t uavpal_connect_stick "... running pppd to establish connection to mobile network using APN \"$(conf_read apn)\" (configured in the conf/apn file)"
	/data/ftp/uavpal/bin/pppd \
		${serial_ppp_dev} \
		connect "/data/ftp/uavpal/bin/chat -v -f  /data/ftp/uavpal/conf/chatscript -T $(conf_read apn)" \
		noipdefault \
		defaultroute \
		replacedefaultroute \
		hide-password \
		noauth \
		persist \
		usepeerdns \
		maxfail 0 \
		lcp-echo-failure 10 \
		lcp-echo-interval 6 \
		holdoff 5

	until [ -d "/proc/sys/net/ipv4/conf/${ppp_if}" ]; do usleep 100000; done
	ulogger -s -t uavpal_connect_stick "... interface \"${ppp_if}\" is up"
	echo $serial_ctrl_dev >/tmp/serial_ctrl_dev
}

detect_ethernet_iface()
{
	configured_iface=$(modem_conf_read MODEM_ETH_IFACE "")
	if [ "$configured_iface" != "" ]; then
		for i in $(seq 1 100); do
			if [ -d "/proc/sys/net/ipv4/conf/${configured_iface}" ]; then
				echo "$configured_iface"
				return 0
			fi
			usleep 100000
		done
		return 1
	fi

	for i in $(seq 1 100); do
		for iface_path in /proc/sys/net/ipv4/conf/eth* /proc/sys/net/ipv4/conf/usb* /proc/sys/net/ipv4/conf/wwan* /proc/sys/net/ipv4/conf/enx*; do
			if [ ! -d "$iface_path" ]; then
				continue
			fi
			iface=$(basename "$iface_path")
			if [ "$iface" == "eth0" ]; then
				continue
			fi
			echo "$iface"
			return 0
		done
		usleep 100000
	done
	return 1
}

connect_ethernet()
{
	modem_if="$1"
	dhcp_script="/tmp/uavpal_udhcpc.sh"

	ulogger -s -t uavpal_connect_ethernet "... bringing up Ethernet modem interface ${modem_if}"
	ifconfig ${modem_if} up
	rm -f /tmp/modem_router_ip

	cat >$dhcp_script <<'EOF'
#!/bin/sh
if [ "$1" == "bound" ] || [ "$1" == "renew" ]; then
	ifconfig "$interface" "$ip" netmask "$subnet"
	for router_ip in $router; do
		ip route add default via "$router_ip" dev "$interface" 2>/dev/null
		echo "$router_ip" >/tmp/modem_router_ip
		break
	done
fi
EOF
	chmod +x $dhcp_script

	ulogger -s -t uavpal_connect_ethernet "... requesting IP address from modem's DHCP server"
	dhcp_result=$(udhcpc -i ${modem_if} -n -t 10 -s $dhcp_script 2>&1)
	if [ "$?" -ne "0" ]; then
		ulogger -s -t uavpal_connect_ethernet "... DHCP did not complete on ${modem_if}: ${dhcp_result}"
	fi

	if [ ! -f /tmp/modem_router_ip ]; then
		modem_ip=$(echo "$dhcp_result" | grep obtained | awk '{ print $4 }')
		if [ "$modem_ip" != "" ]; then
			modem_router_ip=$(echo `echo $modem_ip | cut -d '.' -f 1,2,3`.1)
			ifconfig ${modem_if} ${modem_ip} netmask 255.255.255.0
			ip route add default via ${modem_router_ip} dev ${modem_if} 2>/dev/null
			echo $modem_router_ip >/tmp/modem_router_ip
		fi
	fi

	if [ -f /tmp/modem_router_ip ]; then
		ulogger -s -t uavpal_connect_ethernet "... default gateway is $(cat /tmp/modem_router_ip)"
	fi
	echo $modem_if >/tmp/modem_iface
}

connection_handler_hilink()
{
	while true; do
		check_connection
		if [ $? -ne 0 ]; then
			ulogger -s -t uavpal_connection_handler_hilink "... Internet connection lost, trying to reconnect"
			hilink_api "post" "/api/dialup/mobile-dataswitch" "<request><dataswitch>0</dataswitch></request>"
			sleep 1
			hilink_api "post" "/api/dialup/mobile-dataswitch" "<request><dataswitch>1</dataswitch></request>"
			killall -9 udhcpc
			ifconfig ${cdc_if} down
			ip route del default via $(cat /tmp/hilink_router_ip)
			sleep 1
			connect_hilink
		fi
		sleep 5
	done
}

connection_handler_stick()
{ 
	while true; do
		check_connection
		if [ $? -ne 0 ]; then
			ulogger -s -t uavpal_connection_handler_stick "... Internet connection lost, trying to reconnect"
			killall -9 pppd
			killall -9 chat
			ifconfig ${ppp_if} down
			sleep 1
			connect_stick
		fi
		sleep 5
	done
}

connection_handler_ethernet()
{
	modem_if="$1"
	while true; do
		check_connection
		if [ $? -ne 0 ]; then
			ulogger -s -t uavpal_connection_handler_ethernet "... Internet connection lost, trying to reconnect"
			killall -9 udhcpc
			ifconfig ${modem_if} down
			if [ -f /tmp/modem_router_ip ]; then
				ip route del default via $(cat /tmp/modem_router_ip) 2>/dev/null
			fi
			sleep 1
			connect_ethernet "$modem_if"
		fi
		sleep 5
	done
}

modem_signal_from_csq()
{
	signal_rssi="$1"
	case "$signal_rssi" in
		''|*[!0-9]*) echo "n/a"; return 0 ;;
	esac
	if [ "$signal_rssi" -ge 0 ] && [ "$signal_rssi" -le 31 ]; then
		signal_percentage=$(printf "%.0f\n" $(/data/ftp/uavpal/bin/dc -e "$signal_rssi 1 + 3.13 * p"))
		echo "${signal_percentage}%"
	else
		echo "n/a"
	fi
}

json_value()
{
	echo "$1" | tr '{},' '\n' | grep "\"$2\"" | head -n 1 | cut -d ':' -f 2- | sed 's/^[ 	"]*//;s/[ 	",}]*$//'
}

modem_status_huawei_stick()
{
	modeString=$(at_command "AT\^SYSINFOEX" "OK" "1" | grep "SYSINFOEX:" | tail -n 1)
	modeNum=`echo $modeString | cut -d "," -f 8`
	case "$modeNum" in
		''|*[!0-9]*) modeNum=0 ;;
	esac
	if [ $modeNum -ge 101 ]; then
		mode="4G"
	elif [ $modeNum -ge 23 ] && [ $modeNum -le 65 ]; then
		mode="3G"
	elif [ $modeNum -ge 1 ] && [ $modeNum -le 3 ]; then
		mode="2G"
	else
		mode="n/a"
	fi
	signalString=$(at_command "AT+CSQ" "OK" "1" | grep "CSQ:" | tail -n 1)
	signalRSSI=`echo $signalString | awk '{print $2}' | cut -d ',' -f 1`
	signalPercentage=$(modem_signal_from_csq "$signalRSSI")
	echo "$mode/$signalPercentage"
}

modem_status_hilink()
{
	modeStr=$(hilink_api "get" "/api/device/information" | xmllint --xpath 'string(//workmode)' -)
	if [ "$modeStr" == "LTE" ]; then
		mode="4G"
	elif [ "$modeStr" == "WCDMA" ]; then
		mode="3G"
	elif [ "$modeStr" == "GSM" ]; then
		mode="2G"
	else
		mode="n/a"
	fi
	signalBars=$(hilink_api "get" "/api/monitoring/status" | xmllint --xpath 'string(//SignalIcon)' -)
	case "$signalBars" in
		''|*[!0-9]*) signalBars="" ;;
	esac
	if [ "$signalBars" != "" ]; then
		signalPercentage=$(echo "$signalBars 20 * p" | /data/ftp/uavpal/bin/dc)%
	else
		signalPercentage="n/a"
	fi
	echo "$mode/$signalPercentage"
}

modem_status_usb8l()
{
	status_json=$(/data/ftp/uavpal/bin/curl -s --connect-timeout 1 --max-time 2 "http://192.168.1.1/srv/status" 2>/dev/null)
	if [ "$status_json" == "" ]; then
		return 1
	fi
	mode=$(json_value "$status_json" "statusBarTechnology")
	if [ "$mode" == "" ]; then
		mode=$(json_value "$status_json" "statusBarNetwork")
	fi
	if [ "$mode" == "" ]; then
		mode=$(json_value "$status_json" "technology")
	fi
	if [ "$mode" == "" ]; then
		mode=$(json_value "$status_json" "network")
	fi
	if [ "$mode" == "" ]; then
		mode="n/a"
	fi
	signalBars=$(json_value "$status_json" "statusBarSignalBars")
	if [ "$signalBars" == "" ]; then
		signalBars=$(json_value "$status_json" "signalBars")
	fi
	if [ "$signalBars" == "" ]; then
		signalBars=$(json_value "$status_json" "signal_bars")
	fi
	case "$signalBars" in
		''|*[!0-9]*) signalBars="" ;;
	esac
	if [ "$signalBars" != "" ] && [ "$signalBars" -ge 0 ] && [ "$signalBars" -le 5 ]; then
		signalPercentage=$(echo "$signalBars 20 * p" | /data/ftp/uavpal/bin/dc)%
	else
		signalPercentage="n/a"
	fi
	echo "$mode/$signalPercentage"
}

modem_status_quectel()
{
	if [ "$serial_ctrl_dev" == "" ] || [ ! -c "/dev/${serial_ctrl_dev}" ]; then
		serial_ctrl_dev=$(find_quectel_at_port)
		if [ "$serial_ctrl_dev" == "" ]; then
			return 1
		fi
		echo "$serial_ctrl_dev" >/tmp/serial_ctrl_dev
	fi
	qnwinfo=$(at_command "AT+QNWINFO" "OK" "1" | grep "QNWINFO:" | tail -n 1)
	mode=$(echo "$qnwinfo" | cut -d '"' -f 2)
	if [ "$mode" == "" ]; then
		mode="n/a"
	fi
	signalString=$(at_command "AT+CSQ" "OK" "1" | grep "CSQ:" | tail -n 1)
	signalRSSI=`echo $signalString | awk '{print $2}' | cut -d ',' -f 1`
	signalPercentage=$(modem_signal_from_csq "$signalRSSI")
	echo "$mode/$signalPercentage"
}

modem_status()
{
	if [ -f /tmp/modem_profile ]; then
		modem_profile=$(cat /tmp/modem_profile)
	elif [ -f /tmp/hilink_router_ip ]; then
		modem_profile="huawei_hilink"
	elif [ -f /tmp/serial_ctrl_dev ]; then
		modem_profile="huawei_stick"
	else
		modem_profile="generic_ethernet"
	fi

	if [ "$modem_profile" == "huawei_hilink" ]; then
		modem_status_hilink
	elif [ "$modem_profile" == "huawei_stick" ]; then
		modem_status_huawei_stick
	else
		modem_provider=""
		if [ -f /tmp/modem_provider ]; then
			modem_provider=$(cat /tmp/modem_provider)
		elif [ -f /tmp/modem_usb_id ]; then
			modem_provider=$(modem_provider_from_usb_id "$(cat /tmp/modem_usb_id)")
		fi
		if [ "$modem_provider" == "quectel" ]; then
			status=$(modem_status_quectel)
			if [ "$status" != "" ]; then
				echo "$status"
				return 0
			fi
		fi
		status=$(modem_status_usb8l)
		if [ "$status" != "" ]; then
			echo "$status"
			return 0
		fi
		echo "n/a/n/a"
	fi
}

check_connection()
{
	ping_retries_per_destination=2
	ping_destinations="8.8.8.8 192.5.5.241 199.7.83.42" # google-public-dns-a.google.com, f.root-servers.org, l.root-servers.org
	for check in $ping_destinations; do
		for i in $(seq 1 $ping_retries_per_destination); do
			ping -W 5 -c 1 $check >/dev/null 2>&1
			if [ $? -eq 0 ]; then
				return 0
			fi
			sleep 1
		done
	done
	# none of the ping destinations could have been reached
	return 1
}
