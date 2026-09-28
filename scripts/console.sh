#!/usr/bin/env bash
# The board's serial console as a launch process. Configures the port and
# streams it to stdout, one line per line, so the firmware's output
# interleaves with the ROS logs under its own prefix. Ends with the launch
# and releases the device -- nothing to detach, no session left holding
# the port.
set -euo pipefail

DEV=${1:-/dev/ttyUSB1}

if [ ! -c "$DEV" ]; then
  echo "console: $DEV is not present (board unplugged, or enumerated elsewhere: ls /dev/ttyUSB*)"
  exit 1
fi

stty -F "$DEV" 115200 raw -echo -echoe -echok -crtscts cs8 -parenb -cstopb

echo "console: $DEV at 115200"

# Line-buffered so each line appears as the board finishes it; the CRs the
# firmware sends are stripped so the log stays clean.
exec stdbuf -oL tr -d '\r' < "$DEV"
