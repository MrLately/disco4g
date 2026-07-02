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

	if [ -f /tmp/hilink_router_ip ]; then
		hilink_router_ip=$(head -1 /tmp/hilink_router_ip | tr -d '\r\n' | tr -d '\n')
	fi
	if [ -z "$hilink_router_ip" ]; then
		return
	fi

	sessionInfo=$(/data/ftp/uavpal/bin/curl -s -m 3 -X GET "http://${hilink_router_ip}/api/webserver/SesTokInfo" -H "X-Requested-With: XMLHttpRequest" -H "Referer: http://${hilink_router_ip}/" 2>/dev/null)
	if [ "$?" -ne "0" ] || [ -z "$sessionInfo" ]; then
		ulogger -s -t uavpal_hilink_api "... Error connecting to Hi-Link API"
		return
	fi
	cookie=$(echo "$sessionInfo" | xmllint --xpath 'string(//SesInfo)' - 2>/dev/null | tr -d '\r\n' | tr -d '\n')
	token=$(echo "$sessionInfo" | xmllint --xpath 'string(//TokInfo)' - 2>/dev/null | tr -d '\r\n' | tr -d '\n')
	if [ -z "$cookie" ]; then
		cookie=$(echo "$sessionInfo" | sed -n 's:.*<SesInfo>\([^<]*\)</SesInfo>.*:\1:p' | head -n 1 | tr -d '\r\n' | tr -d '\n')
	fi
	if [ -z "$token" ]; then
		token=$(echo "$sessionInfo" | sed -n 's:.*<TokInfo>\([^<]*\)</TokInfo>.*:\1:p' | head -n 1 | tr -d '\r\n' | tr -d '\n')
	fi
	if [ -f /tmp/hilink_login_required ]; then
		sessionInfoLogin=$(/data/ftp/uavpal/bin/curl -s -m 5 -X POST "http://${hilink_router_ip}/api/user/login" -d "<request><Username>admin</Username><Password>$(echo -n "admin" |base64)</Password><password_type>3</password_type></request>" -H "Cookie: $cookie" -H "__RequestVerificationToken: $token" -H "X-Requested-With: XMLHttpRequest" -H "Referer: http://${hilink_router_ip}/" --dump-header - 2>/dev/null)
		if echo -n "$sessionInfoLogin" | grep '<code>108006\|<code>108007' ; then
			ulogger -s -t uavpal_hilink_api "... Hi-Link authentication error. Please disable password protection or set it to user=admin, password=admin"
			return # break out function
		fi
		login_cookie=$(echo "$sessionInfoLogin" | tr -d '\r' | sed -n 's/^Set-Cookie:[[:space:]]*\([^;]*\).*/\1/p' | head -n 1 | tr -d '\r\n' | tr -d '\n')
		if [ -n "$login_cookie" ]; then
			cookie="$login_cookie"
		fi
		sessionInfoAdm=$(/data/ftp/uavpal/bin/curl -s -m 3 -X GET "http://${hilink_router_ip}/api/webserver/SesTokInfo" -H "Cookie: $cookie" -H "X-Requested-With: XMLHttpRequest" -H "Referer: http://${hilink_router_ip}/" 2>/dev/null)
		token=$(echo "$sessionInfoAdm" | xmllint --xpath 'string(//TokInfo)' - 2>/dev/null | tr -d '\r\n' | tr -d '\n')
		if [ -z "$token" ]; then
			token=$(echo "$sessionInfoAdm" | sed -n 's:.*<TokInfo>\([^<]*\)</TokInfo>.*:\1:p' | head -n 1 | tr -d '\r\n' | tr -d '\n')
		fi
	fi
	if [ "$method" = "POST" ]; then
		result=$(/data/ftp/uavpal/bin/curl -s -m 4 -X POST "http://${hilink_router_ip}${url}" -d "$data" -H "Cookie: $cookie" -H "__RequestVerificationToken: $token" -H "X-Requested-With: XMLHttpRequest" -H "Referer: http://${hilink_router_ip}/" 2>/dev/null)
	else
		result=$(/data/ftp/uavpal/bin/curl -s -m 4 -X GET "http://${hilink_router_ip}${url}" -H "Cookie: $cookie" -H "__RequestVerificationToken: $token" -H "X-Requested-With: XMLHttpRequest" -H "Referer: http://${hilink_router_ip}/" 2>/dev/null)
	fi
	if echo "$result" | grep "<error>" ; then
		error_code=$(echo "$result" | xmllint --xpath 'string(//error/code)' - 2>/dev/null)
		if [ "$error_code" = "100003" ] || [ "$error_code" = "125002" ]; then
			if [ "${HILINK_AUTH_RETRY:-0}" -eq 0 ]; then
				ulogger -s -t uavpal_hilink_api "... Hi-Link authentication required (error ${error_code}). Trying login using user=admin, password=admin"
				touch /tmp/hilink_login_required
				result=$(HILINK_AUTH_RETRY=1 hilink_api "$1" "$2" "$3")
			else
				ulogger -s -t uavpal_hilink_api "... Hi-Link authentication retry failed (error ${error_code})"
			fi
		else
			ulogger -s -t uavpal_hilink_api "... Hi-Link returned Error Code: ${error_code}"
		fi
	fi
	echo "$result"
}

firewall()
{
	# Security: block incoming connections on the Internet interface
	# these connections should only be allowed on Wi-Fi (eth0) and via zerotier (zt*)
	ulogger -s -t uavpal_drone "... applying iptables security rules for interface ${1}"
	iptables -N UAVPAL_INPUT 2>/dev/null
	iptables -F UAVPAL_INPUT 2>/dev/null
	if ! iptables -L INPUT -n 2>/dev/null | grep -q "UAVPAL_INPUT"; then
		iptables -I INPUT -j UAVPAL_INPUT 2>/dev/null
	fi
	ip_block='21 23 51 61 873 8888 9050 44444 67 5353 14551'
	for i in $ip_block; do iptables -A UAVPAL_INPUT -p tcp -i ${1} --dport $i -j DROP; done
}

conf_read()
{
	result=$(head -1 /data/ftp/uavpal/conf/${1})
	echo "$result" |tr -d '\r\n' |tr -d '\n'
}

load_modem_config()
{
	MODEM_PROFILE="auto"
	MODEM_USB_IDS="12d1:* 19d2:* 2c7c:* 1199:* 2dee:* 05c6:* 1bc7:* 413c:* 1410:*"
	MODEM_ETH_IFACE="auto"
	MODEM_ETH_IFACE_PREFIXES="eth usb wwan enx"
	MODEM_PPP_IFACE="ppp0"
	MODEM_SERIAL_CTRL="auto"
	MODEM_SERIAL_PPP="auto"
	MODEM_ENABLE_USB_MODESWITCH="auto"
	MODEM_USB_MODESWITCH_VENDOR="12d1"
	MODEM_USB_MODESWITCH_ARGS="--huawei-new-mode -s 3"
	MODEM_HILINK_DMZ="1"
	MODEM_HILINK_FULLCONE_NAT="1"
	MODEM_LOW_LATENCY_TXQLEN="100"

	if [ -f /data/ftp/uavpal/conf/modem.conf ]; then
		. /data/ftp/uavpal/conf/modem.conf
	fi

	if [ -n "$MODEM_PPP_IFACE" ]; then
		ppp_if="$MODEM_PPP_IFACE"
	fi
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

MODEM_LOW_LATENCY_TXQLEN=$(modem_conf_read MODEM_LOW_LATENCY_TXQLEN "100")

detect_usb_modem()
{
	matched_usb_id=""
	matched_usb_vendor=""
	matched_usb_product=""
	matched_usb_desc=""

	while read -r line; do
		usb_id=$(echo "$line" | awk '{for (i=1; i<=NF; i++) if ($i=="ID") { print $(i+1); exit }}' | tr 'A-Z' 'a-z')
		[ -z "$usb_id" ] && continue
		for pattern in $MODEM_USB_IDS; do
			pattern_lc=$(echo "$pattern" | tr 'A-Z' 'a-z')
			case "$usb_id" in
			$pattern_lc)
				matched_usb_id="$usb_id"
				matched_usb_vendor=$(echo "$usb_id" | cut -d ':' -f 1)
				matched_usb_product=$(echo "$usb_id" | cut -d ':' -f 2)
				matched_usb_desc=$(echo "$line" | sed 's/.*ID [0-9A-Fa-f]\{4\}:[0-9A-Fa-f]\{4\} //')
				return 0
				;;
			*)
				;;
			esac
		done
	done <<EOF
$(lsusb 2>/dev/null)
EOF

	return 1
}

is_quectel_ecm_modem()
{
	quectel_usb_id="$matched_usb_id"
	if [ -z "$quectel_usb_id" ] && [ -f /tmp/modem_usb_id ]; then
		quectel_usb_id=$(head -1 /tmp/modem_usb_id | tr -d '\r\n' | tr -d '\n')
	fi
	case "$quectel_usb_id" in
	2c7c:*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

quectel_bind_option_driver()
{
	is_quectel_ecm_modem || return 1
	echo "quectel_ecm" >/tmp/modem_provider
	quectel_bind_usb_id="$matched_usb_id"
	quectel_bind_vendor="$matched_usb_vendor"
	quectel_bind_product="$matched_usb_product"
	if [ -z "$quectel_bind_usb_id" ] && [ -f /tmp/modem_usb_id ]; then
		quectel_bind_usb_id=$(head -1 /tmp/modem_usb_id | tr -d '\r\n' | tr -d '\n')
	fi
	if [ -z "$quectel_bind_vendor" ] && [ -n "$quectel_bind_usb_id" ]; then
		quectel_bind_vendor=$(echo "$quectel_bind_usb_id" | cut -d ':' -f 1)
	fi
	if [ -z "$quectel_bind_product" ] && [ -n "$quectel_bind_usb_id" ]; then
		quectel_bind_product=$(echo "$quectel_bind_usb_id" | cut -d ':' -f 2)
	fi

	if ls /dev/ttyUSB* >/dev/null 2>&1; then
		return 0
	fi

	if [ -w /sys/bus/usb-serial/drivers/option1/new_id ]; then
		ulogger -s -t uavpal_quectel "... binding Quectel ECM serial interfaces to option driver"
		if [ -n "$quectel_bind_vendor" ] && [ -n "$quectel_bind_product" ]; then
			echo "${quectel_bind_vendor} ${quectel_bind_product}" >/sys/bus/usb-serial/drivers/option1/new_id 2>/dev/null
			sleep 2
		fi
	fi

	if ls /dev/ttyUSB* >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

run_usb_modeswitch()
{
	if [ ! -x /data/ftp/uavpal/bin/usb_modeswitch ]; then
		return 0
	fi

	if [ -z "$matched_usb_vendor" ] || [ -z "$matched_usb_product" ]; then
		return 1
	fi

	case "$MODEM_ENABLE_USB_MODESWITCH" in
	0 | false | no | off)
		return 0
		;;
	auto)
		modeswitch_vendor_lc=$(echo "$MODEM_USB_MODESWITCH_VENDOR" | tr 'A-Z' 'a-z')
		if [ "$matched_usb_vendor" != "$modeswitch_vendor_lc" ]; then
			return 0
		fi
		;;
	*)
		;;
	esac

	ulogger -s -t uavpal_drone "... running usb_modeswitch for ${matched_usb_vendor}:${matched_usb_product}"
	/data/ftp/uavpal/bin/usb_modeswitch -v "$matched_usb_vendor" -p "$matched_usb_product" $MODEM_USB_MODESWITCH_ARGS
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

at_command_on_dev()
{
	dev="$1"
	command="$2"
	expected_response="$3"
	timeout="$4"

	at_lock_dir="/tmp/uavpal_at_command.lock"
	at_lock_wait=15
	at_lock_count=0
	while ! mkdir "$at_lock_dir" 2>/dev/null; do
		at_lock_owner=""
		if [ -f "${at_lock_dir}/pid" ]; then
			at_lock_owner=$(cat "${at_lock_dir}/pid" 2>/dev/null)
		fi
		if [ -n "$at_lock_owner" ] && ! kill -0 "$at_lock_owner" 2>/dev/null; then
			rm -rf "$at_lock_dir"
			continue
		fi
		at_lock_count=$((at_lock_count + 1))
		if [ "$at_lock_count" -ge "$at_lock_wait" ]; then
			ulogger -s -t uavpal_at_command "... timed out waiting for AT command lock for $command"
			return 1
		fi
		sleep 1
	done
	echo "$$" > "${at_lock_dir}/pid"

	result=$(/data/ftp/uavpal/bin/chat -V -t "$timeout" '' "$command" "$expected_response" '' > /dev/${dev} < /dev/${dev}) 2>&1
	rc="$?"

	if [ -f "${at_lock_dir}/pid" ] && [ "$(cat "${at_lock_dir}/pid" 2>/dev/null)" = "$$" ]; then
		rm -rf "$at_lock_dir"
	fi

	echo "$result"
	return "$rc"
}

probe_serial_ctrl_dev()
{
	probe_timeout="$1"
	if [ -z "$probe_timeout" ]; then
		probe_timeout="1"
	fi

	if is_quectel_ecm_modem; then
		quectel_bind_option_driver >/dev/null 2>&1
		if [ -c /dev/ttyUSB2 ]; then
			probe_result=$(at_command_on_dev "ttyUSB2" "AT" "OK" "$probe_timeout")
			if [ "$?" -eq "0" ] && echo "$probe_result" | grep -q "OK"; then
				if [ "$serial_ctrl_dev" != "ttyUSB2" ]; then
					ulogger -s -t uavpal_at_command "... using ttyUSB2 as Quectel ECM control interface"
				fi
				serial_ctrl_dev="ttyUSB2"
				echo "$serial_ctrl_dev" >/tmp/serial_ctrl_dev
				return 0
			fi
		fi
	fi

	candidates=""
	if [ -n "$serial_ctrl_dev" ] && [ -c "/dev/${serial_ctrl_dev}" ]; then
		candidates="$candidates /dev/${serial_ctrl_dev}"
	fi
	for dev in /dev/ttyUSB* /dev/ttyACM*; do
		[ -c "$dev" ] || continue
		candidates="$candidates $dev"
	done

	seen=" "
	for dev in $candidates; do
		[ -c "$dev" ] || continue
		candidate=$(basename "$dev")
		case "$seen" in
			*" $candidate "*)
				continue
				;;
			*)
				;;
		esac
		seen="$seen$candidate "
		if [ -n "$serial_ppp_dev" ] && [ "$candidate" = "$serial_ppp_dev" ]; then
			continue
		fi
		probe_result=$(at_command_on_dev "$candidate" "AT" "OK" "$probe_timeout")
		if [ "$?" -eq "0" ] && echo "$probe_result" | grep -q "OK"; then
			if [ "$serial_ctrl_dev" != "$candidate" ]; then
				ulogger -s -t uavpal_at_command "... using ${candidate} as modem serial control interface"
			fi
			serial_ctrl_dev="$candidate"
			echo "$serial_ctrl_dev" >/tmp/serial_ctrl_dev
			return 0
		fi
	done

	return 1
}

at_command()
{
	command="$1"
	expected_response="$2"
	timeout="$3"

	if [ -z "$timeout" ]; then
		timeout="1"
	fi

	if [ -z "$serial_ctrl_dev" ] && [ -f /tmp/serial_ctrl_dev ]; then
		serial_ctrl_dev=$(head -1 /tmp/serial_ctrl_dev | tr -d '\r\n' | tr -d '\n')
	fi

	if [ -z "$serial_ctrl_dev" ] || [ ! -c "/dev/${serial_ctrl_dev}" ]; then
		probe_serial_ctrl_dev "$timeout" >/dev/null 2>&1
	fi

	if [ -z "$serial_ctrl_dev" ] || [ ! -c "/dev/${serial_ctrl_dev}" ]; then
		ulogger -s -t uavpal_at_command "... no modem serial control interface available for AT command $command"
		return 1
	fi

	result=$(at_command_on_dev "$serial_ctrl_dev" "$command" "$expected_response" "$timeout")
	rc="$?"

	retry_allowed=0
	case "$command" in
	AT\^SYSINFOEX* | AT+CSQ* | AT)
		retry_allowed=1
		;;
	*)
		;;
	esac

	if [ "$rc" -ne "0" ] && [ "$retry_allowed" -eq "1" ]; then
		previous_serial_ctrl_dev="$serial_ctrl_dev"
		serial_ctrl_dev=""
		if probe_serial_ctrl_dev "$timeout" >/dev/null 2>&1 && [ -n "$serial_ctrl_dev" ] && [ "$serial_ctrl_dev" != "$previous_serial_ctrl_dev" ]; then
			result=$(at_command_on_dev "$serial_ctrl_dev" "$command" "$expected_response" "$timeout")
			rc="$?"
		else
			serial_ctrl_dev="$previous_serial_ctrl_dev"
		fi
	fi

	if [ "$rc" -ne "0" ]; then
		ulogger -s -t uavpal_at_command "... Did not receive expected output from AT command $command"
	fi
	echo "$result"
	return "$rc"
}

quectel_usbnet_mode()
{
	is_quectel_ecm_modem || return 1
	quectel_bind_option_driver >/dev/null 2>&1
	serial_ctrl_dev=""
	probe_serial_ctrl_dev "2" >/dev/null 2>&1
	mode_result=$(at_command 'AT+QCFG="usbnet"' "OK" "2")
	mode_rc="$?"
	echo "$mode_result" | sed -n 's/.*+QCFG: "usbnet",\([0-9][0-9]*\).*/\1/p' | tail -n 1
	return "$mode_rc"
}

quectel_require_ecm()
{
	is_quectel_ecm_modem || return 0
	echo "quectel_ecm" >/tmp/modem_provider

	quectel_mode=""
	for quectel_wait in $(seq 1 10); do
		quectel_mode=$(quectel_usbnet_mode)
		if [ -n "$quectel_mode" ]; then
			break
		fi
		sleep 2
	done

	quectel_ts=$(date +%s)
	if [ "$quectel_mode" = "1" ]; then
		echo "provider=quectel_ecm usbnet_mode=1 ecm_ok=1 error= ts=${quectel_ts}" >/tmp/uavpal_quectel_setup_diag
		ulogger -s -t uavpal_quectel "... Quectel ECM modem detected in usbnet=1"
		return 0
	fi

	if [ -z "$quectel_mode" ]; then
		detect_cdc_iface
		if [ "$?" -eq "0" ] && [ "$cdc_if" = "usb0" ]; then
			quectel_error="quectel_usbnet_unknown_data_iface_present"
			echo "provider=quectel_ecm usbnet_mode= ecm_ok=1 error=${quectel_error} ts=${quectel_ts}" >/tmp/uavpal_quectel_setup_diag
			ulogger -s -t uavpal_quectel "... Quectel ECM usbnet mode not ready over AT, but usb0 is present; continuing generic Ethernet startup"
			return 0
		fi
		quectel_error="quectel_usbnet_unknown"
		ulogger -s -t uavpal_quectel "... Quectel ECM modem detected but usbnet mode could not be verified"
	else
		quectel_error="quectel_usbnet_not_ecm"
		ulogger -s -t uavpal_quectel "... Quectel ECM modem usbnet=${quectel_mode}; ECM usbnet=1 is required"
	fi
	echo "provider=quectel_ecm usbnet_mode=${quectel_mode} ecm_ok=0 error=${quectel_error} ts=${quectel_ts}" >/tmp/uavpal_quectel_setup_diag
	return 1
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
	connect_ethernet || return 1

	hilink_ip="$modem_ip"
	hilink_router_ip="$modem_gateway_ip"
	if [ -z "$hilink_router_ip" ] && [ -n "$hilink_ip" ]; then
		hilink_router_ip="$(echo "$hilink_ip" | cut -d '.' -f 1,2,3).1"
	fi
	if [ -z "$hilink_router_ip" ]; then
		ulogger -s -t uavpal_connect_hilink "... unable to detect Hi-Link router IP"
		return 1
	fi

	echo "$hilink_router_ip" >/tmp/hilink_router_ip
	hilink_profiles=$(hilink_api "get" "/api/dialup/profiles")
	hilink_apn_index=$(echo $hilink_profiles | xmllint --xpath "string(//CurrentProfile)" -)
	hilink_apn=$(echo $hilink_profiles | xmllint --xpath "string(//Profile[${hilink_apn_index}]/ApnName)" -)
	ulogger -s -t uavpal_connect_hilink "... connecting to mobile network using APN \"${hilink_apn}\" (configured in the Hi-Link Web UI)"
}

connect_stick()
{
	ulogger -s -t uavpal_connect_stick "... running pppd to establish connection to mobile network using APN \"$(conf_read apn)\" (configured in the conf/apn file)"
	killall -9 pppd >/dev/null 2>&1
	killall -9 chat >/dev/null 2>&1
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

	ppp_wait_loops=250
	while [ "$ppp_wait_loops" -gt "0" ]; do
		if [ -d "/proc/sys/net/ipv4/conf/${ppp_if}" ]; then
			break
		fi
		usleep 100000
		ppp_wait_loops=$((ppp_wait_loops - 1))
	done

	if [ ! -d "/proc/sys/net/ipv4/conf/${ppp_if}" ]; then
		ulogger -s -t uavpal_connect_stick "... PPP interface \"${ppp_if}\" did not come up (serial PPP dev: ${serial_ppp_dev}, serial CTRL dev: ${serial_ctrl_dev})"
		killall -9 pppd >/dev/null 2>&1
		killall -9 chat >/dev/null 2>&1
		return 1
	fi

	ulogger -s -t uavpal_connect_stick "... interface \"${ppp_if}\" is up"
	echo "${ppp_if}" >/tmp/modem_iface
	echo "ok=1 iface=${ppp_if} gateway= ts=$(date +%s)" >/tmp/uavpal_route_diag
	apply_low_latency_queues
	echo $serial_ctrl_dev >/tmp/serial_ctrl_dev
	return 0
}

list_network_ifaces()
{
	awk -F ':' 'NR>2 { gsub(/ /, "", $1); if ($1 != "") print $1 }' /proc/net/dev
}

is_modem_net_iface_candidate()
{
	iface="$1"

	case "$iface" in
	lo | eth0 | wlan* | zt* | ppp* | sit* | ip6tnl* | tunl* | gre* | gretap* | erspan* | docker* | br* | ifb*)
		return 1
		;;
	*)
		;;
	esac

	dev_path=$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null)
	if [ -n "$dev_path" ] && echo "$dev_path" | grep -q "/usb"; then
		return 0
	fi

	return 1
}

detect_cdc_iface()
{
	if [ -n "$MODEM_ETH_IFACE" ] && [ "$MODEM_ETH_IFACE" != "auto" ]; then
		if [ -d "/proc/sys/net/ipv4/conf/${MODEM_ETH_IFACE}" ]; then
			cdc_if="$MODEM_ETH_IFACE"
			return 0
		fi
	fi

	for prefix in $MODEM_ETH_IFACE_PREFIXES; do
		for iface in $(list_network_ifaces); do
			case "$iface" in
			${prefix}*)
				if is_modem_net_iface_candidate "$iface"; then
					cdc_if="$iface"
					return 0
				fi
				;;
			*)
				;;
			esac
		done
	done

	for iface in $(list_network_ifaces); do
		if is_modem_net_iface_candidate "$iface"; then
			cdc_if="$iface"
			return 0
		fi
	done

	return 1
}

detect_ethernet_iface()
{
	if detect_cdc_iface; then
		echo "$cdc_if"
		return 0
	fi
	return 1
}

detect_serial_devices()
{
	if [ -n "$MODEM_SERIAL_CTRL" ] && [ "$MODEM_SERIAL_CTRL" != "auto" ]; then
		serial_ctrl_dev="$MODEM_SERIAL_CTRL"
	fi
	if [ -n "$MODEM_SERIAL_PPP" ] && [ "$MODEM_SERIAL_PPP" != "auto" ]; then
		serial_ppp_dev="$MODEM_SERIAL_PPP"
	fi

	serial_candidates=""
	for dev in /dev/ttyUSB* /dev/ttyACM*; do
		if [ -c "$dev" ]; then
			serial_candidates="$serial_candidates $dev"
		fi
	done

	first_dev=$(echo "$serial_candidates" | awk '{ print $1 }')
	second_dev=$(echo "$serial_candidates" | awk '{ print $2 }')
	serial_dev_count=$(echo "$serial_candidates" | awk '{ print NF }')

	if [ "$MODEM_SERIAL_CTRL" = "auto" ] || [ -z "$MODEM_SERIAL_CTRL" ]; then
		if ! probe_serial_ctrl_dev 1; then
			if [ -n "$first_dev" ]; then
				serial_ctrl_dev=$(basename "$first_dev")
			fi
		fi
	fi

	if [ "$MODEM_SERIAL_PPP" = "auto" ] || [ -z "$MODEM_SERIAL_PPP" ]; then
		if [ -n "$second_dev" ]; then
			serial_ppp_dev=$(basename "$second_dev")
		elif [ -n "$first_dev" ]; then
			serial_ppp_dev=$(basename "$first_dev")
		fi
		if [ -n "$serial_ctrl_dev" ] && [ "$serial_ppp_dev" = "$serial_ctrl_dev" ] && [ "$serial_dev_count" -gt 1 ]; then
			for dev in $serial_candidates; do
				[ -c "$dev" ] || continue
				candidate=$(basename "$dev")
				if [ "$candidate" != "$serial_ctrl_dev" ]; then
					serial_ppp_dev="$candidate"
					break
				fi
			done
		fi
	fi

	if [ -n "$serial_ctrl_dev" ] && [ -c "/dev/${serial_ctrl_dev}" ]; then
		return 0
	fi

	return 1
}

apply_low_latency_queue()
{
	iface="$1"
	target_qlen="$2"

	[ -n "$iface" ] || return 1
	[ -d "/proc/sys/net/ipv4/conf/${iface}" ] || return 1

	case "$target_qlen" in
	'' | *[!0-9]*)
		return 1
		;;
	*)
		;;
	esac
	[ "$target_qlen" -gt 0 ] || return 0

	current_qlen=$(ifconfig "${iface}" 2>/dev/null | sed -n 's/.*txqueuelen:\([0-9][0-9]*\).*/\1/p' | head -n 1)
	if [ -z "$current_qlen" ]; then
		current_qlen=$(ip link show "${iface}" 2>/dev/null | sed -n 's/.*qlen \([0-9][0-9]*\).*/\1/p' | head -n 1)
	fi

	# Only reduce oversized queues. Never raise small queues such as PPP defaults.
	if [ -n "$current_qlen" ] && [ "$current_qlen" -le "$target_qlen" ]; then
		echo "ok=1 iface=${iface} qlen=${current_qlen} ts=$(date +%s)" >/tmp/uavpal_queue_diag
		return 0
	fi

	if ifconfig "${iface}" txqueuelen "${target_qlen}" >/dev/null 2>&1; then
		echo "ok=1 iface=${iface} qlen=${target_qlen} ts=$(date +%s)" >/tmp/uavpal_queue_diag
		ulogger -s -t uavpal_queue "... set ${iface} txqueuelen=${target_qlen} (was ${current_qlen:-unknown})"
		return 0
	fi
	if ip link set dev "${iface}" txqueuelen "${target_qlen}" >/dev/null 2>&1; then
		echo "ok=1 iface=${iface} qlen=${target_qlen} ts=$(date +%s)" >/tmp/uavpal_queue_diag
		ulogger -s -t uavpal_queue "... set ${iface} txqueuelen=${target_qlen} (was ${current_qlen:-unknown})"
		return 0
	fi

	echo "ok=0 iface=${iface} qlen=${target_qlen} ts=$(date +%s)" >/tmp/uavpal_queue_diag
	return 1
}

apply_low_latency_queues()
{
	case "$MODEM_LOW_LATENCY_TXQLEN" in
	'' | *[!0-9]*)
		return 0
		;;
	*)
		;;
	esac
	[ "$MODEM_LOW_LATENCY_TXQLEN" -gt 0 ] || return 0

	if [ -n "$cdc_if" ]; then
		apply_low_latency_queue "$cdc_if" "$MODEM_LOW_LATENCY_TXQLEN"
	fi
	if [ -n "$ppp_if" ]; then
		apply_low_latency_queue "$ppp_if" "$MODEM_LOW_LATENCY_TXQLEN"
	fi
	if [ -f /tmp/modem_iface ]; then
		apply_low_latency_queue "$(cat /tmp/modem_iface 2>/dev/null)" "$MODEM_LOW_LATENCY_TXQLEN"
	fi
	for iface in $(list_network_ifaces); do
		case "$iface" in
		zt*)
			apply_low_latency_queue "$iface" "$MODEM_LOW_LATENCY_TXQLEN"
			;;
		esac
	done
}

ensure_ethernet_default_route()
{
	route_iface="$1"
	route_gateway="$2"

	if [ -z "$route_gateway" ] && [ -f /tmp/modem_gateway_ip ]; then
		route_gateway=$(head -1 /tmp/modem_gateway_ip | tr -d '\r\n' | tr -d '\n')
	fi
	if [ -z "$route_iface" ] || [ -z "$route_gateway" ]; then
		echo "ok=0 iface=${route_iface} gateway=${route_gateway} ts=$(date +%s)" >/tmp/uavpal_route_diag
		return 1
	fi

	if ip route 2>/dev/null | awk -v dev="$route_iface" -v gw="$route_gateway" '$1=="default" && $3==gw && $5==dev { found=1 } END { exit(found ? 0 : 1) }'; then
		echo "ok=1 iface=${route_iface} gateway=${route_gateway} ts=$(date +%s)" >/tmp/uavpal_route_diag
		return 0
	fi
	if route -n 2>/dev/null | awk -v dev="$route_iface" -v gw="$route_gateway" '$1=="0.0.0.0" && $2==gw && $8==dev { found=1 } END { exit(found ? 0 : 1) }'; then
		echo "ok=1 iface=${route_iface} gateway=${route_gateway} ts=$(date +%s)" >/tmp/uavpal_route_diag
		return 0
	fi

	route_ok=0
	ip route replace default via "$route_gateway" dev "$route_iface" >/dev/null 2>&1
	if [ "$?" -eq 0 ]; then
		route_ok=1
	fi
	if [ "$route_ok" -ne 1 ]; then
		ip route del default dev "$route_iface" >/dev/null 2>&1
		ip route add default via "$route_gateway" dev "$route_iface" >/dev/null 2>&1
		if [ "$?" -eq 0 ]; then
			route_ok=1
		fi
	fi
	if [ "$route_ok" -ne 1 ]; then
		route del default gw "$route_gateway" dev "$route_iface" >/dev/null 2>&1
		route add default gw "$route_gateway" dev "$route_iface" >/dev/null 2>&1
		if [ "$?" -eq 0 ]; then
			route_ok=1
		fi
	fi

	if [ "$route_ok" -eq 1 ]; then
		echo "ok=1 iface=${route_iface} gateway=${route_gateway} ts=$(date +%s)" >/tmp/uavpal_route_diag
		ulogger -s -t uavpal_route "... repaired default route via ${route_gateway} on ${route_iface}"
		return 0
	fi

	echo "ok=0 iface=${route_iface} gateway=${route_gateway} ts=$(date +%s)" >/tmp/uavpal_route_diag
	return 1
}

connect_ethernet()
{
	if [ -n "$1" ]; then
		cdc_if="$1"
	fi
	modem_if="$cdc_if"

	ulogger -s -t uavpal_connect_ethernet "... bringing up modem network interface ${modem_if}"
	ifconfig ${modem_if} up
	echo "$modem_if" >/tmp/modem_iface
	apply_low_latency_queues
	rm -f /tmp/modem_router_ip /tmp/modem_gateway_ip /tmp/modem_ip

	ulogger -s -t uavpal_connect_ethernet "... requesting IP address from modem's DHCP server"
	dhcp_result=$(udhcpc -i ${modem_if} -n -t 10 2>&1)
	if [ "$?" -ne "0" ]; then
		ulogger -s -t uavpal_connect_ethernet "... DHCP did not complete on ${modem_if}: ${dhcp_result}"
	fi

	modem_ip=$(echo "$dhcp_result" | awk '/obtained/ { print $4; exit }')
	modem_gateway_ip=$(echo "$dhcp_result" | awk '/router/ { for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\./) { print $i; exit } }')

	for i in $(seq 1 4); do
		if [ -z "$modem_ip" ]; then
			modem_ip=$(ifconfig "${modem_if}" 2>/dev/null | awk '/inet addr:/{ split($2, a, ":"); print a[2]; exit }')
		fi
		if [ -z "$modem_ip" ]; then
			modem_ip=$(ifconfig "${modem_if}" 2>/dev/null | awk '/inet /{ print $2; exit }')
		fi
		if [ -z "$modem_gateway_ip" ]; then
			modem_gateway_ip=$(ip route 2>/dev/null | awk -v dev="${modem_if}" '$1=="default" && $5==dev { print $3; exit }')
		fi
		if [ -z "$modem_gateway_ip" ]; then
			modem_gateway_ip=$(route -n 2>/dev/null | awk -v dev="${modem_if}" '$1=="0.0.0.0" && $8==dev { print $2; exit }')
		fi
		if [ -n "$modem_ip" ] && [ -n "$modem_gateway_ip" ]; then
			break
		fi
		sleep 1
	done

	if [ -z "$modem_gateway_ip" ] && [ -n "$modem_ip" ]; then
		modem_gateway_ip="$(echo "$modem_ip" | cut -d '.' -f 1,2,3).1"
	fi

	if [ -n "$modem_ip" ]; then
		ulogger -s -t uavpal_connect_ethernet "... setting ${modem_if}'s IP address to ${modem_ip}"
		ifconfig ${modem_if} ${modem_ip} netmask 255.255.255.0
	fi

	if [ -n "$modem_gateway_ip" ]; then
		ulogger -s -t uavpal_connect_ethernet "... setting default route via ${modem_gateway_ip}"
		if ensure_ethernet_default_route "$modem_if" "$modem_gateway_ip"; then
			echo "$modem_gateway_ip" >/tmp/modem_gateway_ip
			echo "$modem_gateway_ip" >/tmp/modem_router_ip
		else
			ulogger -s -t uavpal_connect_ethernet "... failed to install default route via ${modem_gateway_ip} on ${modem_if}"
			modem_gateway_ip=""
		fi
	fi

	echo "$modem_ip" >/tmp/modem_ip

	if [ -z "$modem_ip" ] || [ -z "$modem_gateway_ip" ]; then
		ulogger -s -t uavpal_connect_ethernet "... DHCP/router detection failed on ${modem_if}"
		return 1
	fi

	return 0
}

modem_has_hilink_api()
{
	if [ -z "$modem_gateway_ip" ] && [ -f /tmp/modem_gateway_ip ]; then
		modem_gateway_ip=$(cat /tmp/modem_gateway_ip)
	fi
	if [ -z "$modem_gateway_ip" ]; then
		return 1
	fi

	probe=$(/data/ftp/uavpal/bin/curl -s -m 2 -X GET "http://${modem_gateway_ip}/api/device/information" 2>/dev/null)
	echo "$probe" | grep -q "<response>" || return 1
	echo "$probe" | grep -q "<DeviceName>" || return 1
	return 0
}

connection_handler_hilink()
{
	fail_count=0
	backoff_sec=1
	internet_soft_fail_threshold=12
	while true; do
		apply_low_latency_queues
		check_modem_link_ethernet
		link_ok=$?
		check_connection
		internet_ok=$?
		write_reconnect_diag "hilink" "$fail_count" "$link_ok" "$internet_ok" "$backoff_sec"

		if [ "$link_ok" -eq "0" ] && [ "$internet_ok" -eq "0" ]; then
			fail_count=0
			backoff_sec=1
			sleep 5
			continue
		fi

		fail_count=$((fail_count + 1))

		if [ "$link_ok" -eq "0" ] && [ "$internet_ok" -ne "0" ] && [ "$fail_count" -lt "$internet_soft_fail_threshold" ]; then
			if [ "$fail_count" -eq "2" ]; then
				ulogger -s -t uavpal_connection_handler_hilink "... transient Internet check failure detected (fail_count=${fail_count}), waiting before reconnect"
			fi
			sleep 5
			continue
		fi

		if [ "$link_ok" -ne "0" ] && [ "$fail_count" -lt "2" ]; then
			sleep 5
			continue
		fi

		ulogger -s -t uavpal_connection_handler_hilink "... reconnecting (link_ok=${link_ok}, internet_ok=${internet_ok}, fail_count=${fail_count}, backoff=${backoff_sec}s)"
		sleep "$backoff_sec"
		ulogger -s -t uavpal_connection_handler_hilink "... toggling Hi-Link data connection and renewing Ethernet session"
		hilink_api "post" "/api/dialup/mobile-dataswitch" "<request><dataswitch>0</dataswitch></request>"
		sleep 1
		hilink_api "post" "/api/dialup/mobile-dataswitch" "<request><dataswitch>1</dataswitch></request>"
		killall -9 udhcpc
		ifconfig ${cdc_if} down
		if [ -f /tmp/hilink_router_ip ]; then
			ip route del default via "$(cat /tmp/hilink_router_ip)" dev ${cdc_if} >/dev/null 2>&1
		fi
		rm -f /tmp/modem_gateway_ip /tmp/modem_ip
		sleep 1
		connect_hilink
		fail_count=0
		backoff_sec=$((backoff_sec * 2))
		if [ "$backoff_sec" -gt "10" ]; then
			backoff_sec=10
		fi
		sleep 5
	done
}

connection_handler_stick()
{ 
	fail_count=0
	backoff_sec=1
	internet_soft_fail_threshold=12
	while true; do
		apply_low_latency_queues
		check_modem_link_stick
		link_ok=$?
		check_connection
		internet_ok=$?
		write_reconnect_diag "stick" "$fail_count" "$link_ok" "$internet_ok" "$backoff_sec"

		if [ "$link_ok" -eq "0" ] && [ "$internet_ok" -eq "0" ]; then
			fail_count=0
			backoff_sec=1
			sleep 5
			continue
		fi

		fail_count=$((fail_count + 1))

		if [ "$link_ok" -eq "0" ] && [ "$internet_ok" -ne "0" ] && [ "$fail_count" -lt "$internet_soft_fail_threshold" ]; then
			if [ "$fail_count" -eq "2" ]; then
				ulogger -s -t uavpal_connection_handler_stick "... transient Internet check failure detected (fail_count=${fail_count}), waiting before reconnect"
			fi
			sleep 5
			continue
		fi

		if [ "$link_ok" -ne "0" ] && [ "$fail_count" -lt "2" ]; then
			sleep 5
			continue
		fi

		ulogger -s -t uavpal_connection_handler_stick "... reconnecting (link_ok=${link_ok}, internet_ok=${internet_ok}, fail_count=${fail_count}, backoff=${backoff_sec}s)"
		sleep "$backoff_sec"
		ulogger -s -t uavpal_connection_handler_stick "... restarting PPP session"
		killall -9 pppd
		killall -9 chat
		ifconfig ${ppp_if} down
		sleep 1
		connect_stick
		fail_count=0
		backoff_sec=$((backoff_sec * 2))
		if [ "$backoff_sec" -gt "10" ]; then
			backoff_sec=10
		fi
		sleep 5
	done
}

connection_handler_ethernet()
{
	if [ -n "$1" ]; then
		cdc_if="$1"
	fi
	fail_count=0
	backoff_sec=1
	internet_soft_fail_threshold=12
	while true; do
		apply_low_latency_queues
		ensure_ethernet_default_route "$cdc_if" >/dev/null 2>&1
		check_modem_link_ethernet
		link_ok=$?
		check_connection
		internet_ok=$?
		write_reconnect_diag "ethernet" "$fail_count" "$link_ok" "$internet_ok" "$backoff_sec"

		if [ "$link_ok" -eq "0" ] && [ "$internet_ok" -eq "0" ]; then
			fail_count=0
			backoff_sec=1
			sleep 5
			continue
		fi

		fail_count=$(($fail_count + 1))

		if [ "$link_ok" -eq "0" ] && [ "$internet_ok" -ne "0" ] && zerotier_transport_ok; then
			write_reconnect_diag "ethernet" "$fail_count" "$link_ok" "$internet_ok" "$backoff_sec" "internet_degraded_zt_ok"
			if [ "$fail_count" -eq "2" ] || [ "$fail_count" -eq "$internet_soft_fail_threshold" ] || [ $(($fail_count % 12)) -eq "0" ]; then
				ulogger -s -t uavpal_connection_handler_ethernet "... Internet check degraded, but ZeroTier is OK; keeping modem data path alive"
			fi
			sleep 5
			continue
		fi

		if [ "$link_ok" -eq "0" ] && [ "$internet_ok" -ne "0" ] && [ "$fail_count" -lt "$internet_soft_fail_threshold" ]; then
			if [ "$fail_count" -eq "2" ]; then
				ulogger -s -t uavpal_connection_handler_ethernet "... transient Internet check failure detected (fail_count=${fail_count}), waiting before reconnect"
			fi
			sleep 5
			continue
		fi

		if [ "$link_ok" -ne "0" ] && [ "$fail_count" -lt "2" ]; then
			sleep 5
			continue
		fi

		ulogger -s -t uavpal_connection_handler_ethernet "... reconnecting (link_ok=${link_ok}, internet_ok=${internet_ok}, fail_count=${fail_count}, backoff=${backoff_sec}s)"
		sleep "$backoff_sec"
		ulogger -s -t uavpal_connection_handler_ethernet "... renewing generic Ethernet modem session"
		killall -9 udhcpc
		ifconfig ${cdc_if} down
		if [ -f /tmp/modem_gateway_ip ]; then
			ip route del default via "$(cat /tmp/modem_gateway_ip)" dev ${cdc_if} >/dev/null 2>&1
		elif [ -f /tmp/modem_router_ip ]; then
			ip route del default via "$(cat /tmp/modem_router_ip)" dev ${cdc_if} >/dev/null 2>&1
		fi
		rm -f /tmp/modem_gateway_ip /tmp/modem_router_ip /tmp/modem_ip
		sleep 1
		connect_ethernet
		fail_count=0
		backoff_sec=$(($backoff_sec * 2))
		if [ "$backoff_sec" -gt "10" ]; then
			backoff_sec=10
		fi
		sleep 5
	done
}

write_reconnect_diag()
{
	diag_handler="$1"
	diag_fail_count="$2"
	diag_link_ok="$3"
	diag_internet_ok="$4"
	diag_backoff_sec="$5"
	diag_state="$6"

	if [ -z "$diag_state" ]; then
		if [ "$diag_link_ok" -ne "0" ]; then
			diag_state="link_down"
		elif [ "$diag_internet_ok" -ne "0" ]; then
			diag_state="internet_degraded"
		elif [ "$diag_fail_count" -gt "0" ]; then
			diag_state="recovering"
		else
			diag_state="ready"
		fi
	fi

	echo "handler=${diag_handler} state=${diag_state} fail_count=${diag_fail_count} link_ok=${diag_link_ok} internet_ok=${diag_internet_ok} backoff_sec=${diag_backoff_sec} ts=$(date +%s)" >/tmp/uavpal_reconnect_diag
}

zerotier_transport_ok()
{
	zt_ok_nwid="$(conf_read zt_networkid)"
	if [ -z "$zt_ok_nwid" ] || [ ! -x /data/ftp/uavpal/bin/zerotier-one ]; then
		return 1
	fi
	zt_info_state=$(/data/ftp/uavpal/bin/zerotier-one -q info 2>/dev/null | awk '{ print $5; exit }')
	if [ "$zt_info_state" != "ONLINE" ]; then
		return 1
	fi
	zt_ok_line=$(/data/ftp/uavpal/bin/zerotier-one -q listnetworks 2>/dev/null | awk -v nwid="$zt_ok_nwid" '$3==nwid { print; exit }')
	if [ -z "$zt_ok_line" ]; then
		return 1
	fi
	zt_ok_state=$(echo "$zt_ok_line" | awk '{ for (i=1; i<=NF; i++) if ($i=="OK" || $i=="ACCESS_DENIED" || $i=="REQUESTING_CONFIGURATION" || $i=="NOT_FOUND" || $i=="PORT_ERROR") { print $i; exit } }')
	zt_ok_ip=$(echo "$zt_ok_line" | awk '{ for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) { gsub(/,.*/, "", $i); print $i; exit } }')
	if [ "$zt_ok_state" = "OK" ] && [ -n "$zt_ok_ip" ]; then
		return 0
	fi
	return 1
}

check_modem_link_ethernet()
{
	modem_if="$1"
	if [ -z "$modem_if" ]; then
		modem_if="$cdc_if"
	fi
	if [ -z "$modem_if" ] || [ ! -d "/proc/sys/net/ipv4/conf/${modem_if}" ]; then
		return 1
	fi

	ifconfig "${modem_if}" 2>/dev/null | grep -q "RUNNING" || return 1

	modem_link_gateway=""
	if [ -f /tmp/modem_gateway_ip ]; then
		modem_link_gateway=$(head -1 /tmp/modem_gateway_ip | tr -d '\r\n' | tr -d '\n')
	elif [ -f /tmp/modem_router_ip ]; then
		modem_link_gateway=$(head -1 /tmp/modem_router_ip | tr -d '\r\n' | tr -d '\n')
	fi
	if [ -z "$modem_link_gateway" ]; then
		modem_link_gateway=$(ip route 2>/dev/null | awk -v dev="$modem_if" '$1=="default" && $5==dev {print $3; exit}')
	fi
	if [ -z "$modem_link_gateway" ]; then
		modem_link_gateway=$(route -n 2>/dev/null | awk -v dev="$modem_if" '$1=="0.0.0.0" && $8==dev {print $2; exit}')
	fi

	if [ -n "$modem_link_gateway" ]; then
		return 0
	fi
	return 1
}

check_modem_link_stick()
{
	if [ -z "$ppp_if" ] || [ ! -d "/proc/sys/net/ipv4/conf/${ppp_if}" ]; then
		return 1
	fi

	ifconfig "${ppp_if}" 2>/dev/null | grep -q "RUNNING" || return 1
	return 0
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
		probe_serial_ctrl_dev "1" >/dev/null 2>&1
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
	if [ -f /tmp/modem_connection_profile ]; then
		modem_profile=$(cat /tmp/modem_connection_profile)
	elif [ -f /tmp/modem_profile ]; then
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
		if [ "$modem_provider" == "quectel" ] || [ "$modem_provider" == "quectel_ecm" ]; then
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
	tcp_destinations="1.1.1.1 8.8.8.8"
	nc_cmd=""
	if command -v nc >/dev/null 2>&1; then
		nc_cmd="nc"
	elif [ -x /bin/busybox ] && /bin/busybox | grep -w nc >/dev/null 2>&1; then
		nc_cmd="/bin/busybox nc"
	fi
	if [ -n "$nc_cmd" ]; then
		for check in $tcp_destinations; do
			$nc_cmd -w 2 "$check" 443 < /dev/null >/dev/null 2>&1
			if [ $? -eq 0 ]; then
				return 0
			fi
		done
	fi

	ping_destinations="8.8.8.8 192.5.5.241 199.7.83.42" # google-public-dns-a.google.com, f.root-servers.org, l.root-servers.org
	for check in $ping_destinations; do
		ping -W 2 -c 1 $check >/dev/null 2>&1
		if [ $? -eq 0 ]; then
			return 0
		fi
		sleep 1
	done
	# none of the ping destinations could have been reached
	return 1
}
