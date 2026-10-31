#!/usr/bin/env bash
# The board's serial console as a launch process. Configures the port and
# streams it to stdout, one line per line, so the firmware's output
# interleaves with the ROS logs under its own prefix. Ends with the launch
# and releases the device -- nothing to detach, no session left holding
# the port.
#
# The port is held exclusively while this runs (TIOCEXCL, cleared again on
# the way out). Two readers on one serial port split its bytes between them
# and both see torn lines, so a second console.sh, screen or picocom gets
# "busy" instead of half the output. To follow a run that holds the port,
# read its log rather than the port:
#
#   tail -f "$(ls -t ~/Documents/hwtest-2*.log | head -1)"
set -euo pipefail

DEV=${1:-/dev/ttyUSB1}

if [ ! -c "$DEV" ]; then
  echo "console: $DEV is not present (board unplugged, or enumerated elsewhere: ls /dev/ttyUSB*)"
  exit 1
fi
# An exclusive holder makes every other open fail with EBUSY.
if ! (: <"$DEV") 2>/dev/null; then
  if [ -r "$DEV" ]; then
    echo "console: $DEV is busy: another console or a hwtest run holds it (lsof $DEV shows which)"
  else
    echo "console: $DEV is not readable by $(id -un) (the dialout group?)"
  fi
  exit 1
fi

stty -F "$DEV" 115200 raw -echo -echoe -echok -crtscts cs8 -parenb -cstopb

echo "console: $DEV at 115200"

# The reader: line by line, CRs stripped, the port exclusive until it exits.
# SIGINT (the launch's shutdown), SIGTERM and SIGHUP all end it through the
# same path, which gives the port back.
exec python3 -u - "$DEV" <<'EOF'
import fcntl
import os
import signal
import sys
import termios

dev = sys.argv[1]


def stop(signum, frame):
    raise SystemExit(0)


for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, stop)

try:
    fd = os.open(dev, os.O_RDONLY | os.O_NOCTTY)
except OSError as e:
    print(f'console: {dev}: {e.strerror}', flush=True)
    sys.exit(1)
exclusive = True
try:
    fcntl.ioctl(fd, termios.TIOCEXCL)
except OSError:
    exclusive = False
    print(f'console: could not make {dev} exclusive; a second reader would split its lines',
          flush=True)

out = sys.stdout.buffer
pending = b''
try:
    while True:
        try:
            chunk = os.read(fd, 4096)
        except OSError as e:
            print(f'console: {dev}: {e.strerror}', flush=True)
            break
        if not chunk:
            print(f'console: {dev} went away', flush=True)
            break
        pending += chunk.replace(b'\r', b'')
        *lines, pending = pending.split(b'\n')
        for line in lines:
            out.write(line + b'\n')
        out.flush()
finally:
    if pending:
        out.write(pending + b'\n')
        out.flush()
    if exclusive:
        try:
            fcntl.ioctl(fd, termios.TIOCNXCL)
        except OSError:
            pass
    os.close(fd)
EOF
