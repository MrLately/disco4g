#!/bin/sh

. /data/ftp/uavpal/bin/uavpal_globalfunctions.sh

event_usb_id=$(normalize_usb_id "$PRODUCT")
if [ "$event_usb_id" == "" -o "$event_usb_id" == ":" ]; then
	exit 0
fi

if ! modem_usb_id_allowed "$event_usb_id"; then
	exit 0
fi

if [ "$ACTION" == "remove" ]; then
	ulogger -s -t uavpal_drone "USB modem disconnected (USB ID: ${event_usb_id})"
	/usr/bin/flock -n /tmp/lock/uavpal_unload /data/ftp/uavpal/bin/uavpal_unload.sh
else
	ulogger -s -t uavpal_drone "USB modem detected (USB ID: ${event_usb_id})"
	/usr/bin/flock -n /tmp/lock/uavpal_disco /data/ftp/uavpal/bin/uavpal_disco.sh
fi
