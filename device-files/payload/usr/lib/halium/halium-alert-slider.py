#!/usr/bin/env python3
"""
OnePlus 8 Pro alert slider -> Ubuntu Touch ringer mode.

HOW THE HARDWARE REPORTS ITSELF
-------------------------------
The slider is two hall sensors, driven by
    drivers/misc/tri_state_key/oplus_tri_key.c
which registers an input device named "oplus,hall_tri_state_key" and, in
report_key_value(), reports the position as the *value* of a single keycode:

    position == UP_STATE   -> KEY_F3 value 1
    position == MID_STATE  -> KEY_F3 value 2
    position == DOWN_STATE -> KEY_F3 value 3

each immediately followed by a value 0 (release), which we ignore.  That is
why the device advertises exactly one key bit (KEY=2000000000000000, bit 61
== KEY_F3): the position is in the value, not in the keycode.

The same driver exports the *current* position at /proc/tristatekey/tri_state
(proc_tri_state_read returns g_the_chip->state, set in report_key_value right
beside the input_report_key call, so it is exactly as authoritative as the
events themselves).

WHY WE DO NOT TRUST THE EVENTS ALONE
------------------------------------
Measured on-device: the slider was moved through all three positions, the driver
ended at state 3, and the daemon had only ever received the transition to 1 --
so at least one edge never reached userspace, leaving the phone silent while the
switch said ring.

A three-position switch is a LEVEL, not an edge. So the events are now only used
as a fast wake-up hint, and /proc/tristatekey/tri_state is the source of truth,
re-read on every wake and on a 2 s timeout. A missed edge then costs at most two
seconds instead of wedging the ringer in the wrong mode until the next move.

...EXCEPT AT BOOT
-----------------
tri_state is a cached decision, not a measurement: it is only recomputed when a
hall interrupt or the timeout work fires. If the boot-time decision was made
before the sensors were ready, the wrong value simply sits there. Measured with
the switch physically at 3 the whole time, the driver reported 1 for 29 s on one
boot and 135 s on the next. So for the initial profile we ignore tri_state and
compute the position ourselves from /proc/tristatekey/hall_data, which is
re-measured on every read, using the driver's own reboot_get_position() rule.
We switch over to tri_state once it agrees with the sensors. See
settle_initial_position() and position_from_hall().

WHAT WE SET
-----------
Ubuntu Touch keeps the ringer profile in AccountsService, interface
com.lomiri.touch.AccountsService.Sound.  The indicator and the shell both
watch those properties, so writing them is the supported way in - no poking
at the indicator or at PulseAudio directly.

    silent  : SilentMode=true,  vibrate-in-silent OFF
    vibrate : SilentMode=true,  vibrate-in-silent ON
    ring    : SilentMode=false

Only those three properties are touched.  The user's own IncomingCallVibrate /
IncomingMessageVibrate preferences are left alone, so sliding back to "ring"
restores exactly the profile they configured.
"""

import os
import glob
import select
import struct
import subprocess
import sys
import time

UID = 32011                      # phablet
KEY_F3 = 61
EV_KEY = 1
DEVNAME = "oplus,hall_tri_state_key"
STATE_PROC = "/proc/tristatekey/tri_state"
HALL_PROC = "/proc/tristatekey/hall_data"
CONFIG = "/etc/halium-alert-slider.conf"
POLL_MS = 2000
SETTLE_SECS = 120                # how long to wait for the hall sensors at boot
DEBUG = os.path.exists("/userdata/.slider-debug")

# struct input_event on 64-bit: __kernel_ulong_t tv_sec, tv_usec; __u16 type,
# code; __s32 value  =  8 + 8 + 2 + 2 + 4 = 24 bytes
EVENT_FMT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FMT)
assert EVENT_SIZE == 24

# position value from the driver -> profile name
DEFAULT_MAP = {1: "silent", 2: "vibrate", 3: "ring"}

PROFILES = {
    # name       SilentMode  vibrate-in-silent
    "silent":  (True,  False),
    "vibrate": (True,  True),
    "ring":    (False, None),   # None = leave the silent-mode vibrate flags alone
}


def log(msg):
    print(msg, flush=True)


def load_map():
    """Allow the up/down mapping to be flipped without editing this file."""
    mapping = dict(DEFAULT_MAP)
    try:
        with open(CONFIG) as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if not line or "=" not in line:
                    continue
                k, v = (x.strip() for x in line.split("=", 1))
                if k in ("1", "2", "3") and v in PROFILES:
                    mapping[int(k)] = v
    except FileNotFoundError:
        pass
    return mapping


def find_device():
    """Locate the slider by NAME - event node numbers are not stable."""
    for path in sorted(glob.glob("/sys/class/input/event*")):
        try:
            with open(os.path.join(path, "device", "name")) as fh:
                if fh.read().strip() == DEVNAME:
                    return "/dev/input/" + os.path.basename(path)
        except OSError:
            continue
    return None


def set_prop(name, value):
    subprocess.run(
        ["dbus-send", "--system", "--print-reply",
         "--dest=org.freedesktop.Accounts",
         "/org/freedesktop/Accounts/User%d" % UID,
         "org.freedesktop.DBus.Properties.Set",
         "string:com.lomiri.touch.AccountsService.Sound",
         "string:" + name,
         "variant:boolean:" + ("true" if value else "false")],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def buzz(ms=40):
    """Short confirmation buzz. Only used when entering vibrate mode."""
    base = "/sys/class/leds/vibrator"
    try:
        if os.path.exists(base + "/duration"):
            with open(base + "/duration", "w") as fh:
                fh.write(str(ms))
        with open(base + "/activate", "w") as fh:
            fh.write("1")
    except OSError:
        pass


def apply_profile(name):
    silent, vib_in_silent = PROFILES[name]
    set_prop("SilentMode", silent)
    if vib_in_silent is not None:
        set_prop("IncomingCallVibrateSilentMode", vib_in_silent)
        set_prop("IncomingMessageVibrateSilentMode", vib_in_silent)
    log("slider -> %s" % name)
    if name == "vibrate":
        buzz()


def read_hall_data():
    """Live (dhall_data0, dhall_data1) from the two hall sensors, or None.

    proc_hall_data_read() in oplus_tri_key.c calls oplus_hall_get_data(DHALL_0)
    and (DHALL_1) on every read and then prints "%d, %d" of dhall_data0 and
    dhall_data1, so unlike tri_state this is always a *fresh* measurement rather
    than a cached decision. It prints a lone "-1" if the chip is not up yet.
    """
    try:
        with open(HALL_PROC) as fh:
            parts = [p.strip() for p in fh.read().strip().split(",")]
        if len(parts) != 2:
            return None                      # "-1": driver not ready
        d0, d1 = int(parts[0]), int(parts[1])
    except (OSError, ValueError):
        return None
    if d0 == 0 and d1 == 0:
        return None                          # sensors not sampled yet
    return d0, d1


def position_from_hall(d0, d1):
    """The driver's own boot-time rule, applied to data we know is fresh.

    This is reboot_get_position() from oplus_tri_key.c transcribed exactly:

        if (dhall_data1 < 0 || dhall_data0 < 0) {
            up_data1   = -dhall_data1;
            down_data1 = -dhall_data0;
            delta = up_data1 - down_data1;
        } else
            delta = dhall_data1 - dhall_data0;
        if (delta > 30)        position = UP_STATE;
        else if (-delta > 30)  position = DOWN_STATE;
        else                   position = MID_STATE;

    UP/MID/DOWN are reported to userspace as 1/2/3 (see the module docstring).
    """
    if d1 < 0 or d0 < 0:
        delta = (-d1) - (-d0)
    else:
        delta = d1 - d0
    if delta > 30:
        return 1                             # UP_STATE
    if -delta > 30:
        return 3                             # DOWN_STATE
    return 2                                 # MID_STATE


def settle_initial_position(mapping):
    """Return a boot position worth acting on, or None if we never got one.

    WHY THIS DOES NOT USE read_current_position()
    ---------------------------------------------
    register_tri_key_dev_work() in oplus_tri_key.c calls init_trikey_proc() --
    which publishes /proc/tristatekey/tri_state -- BEFORE it calls
    report_key_value(), the only place chip->state is ever assigned. Worse,
    chip->state is a *cached decision*: it is only recomputed when a hall
    interrupt or the timeout work fires, so if the boot-time decision was made
    from sensor data that was not ready yet, the wrong value simply sits there.

    Measured across two boots, with the switch physically at position 3 the
    whole time:
        boot A: reported 1, corrected to 3 after  29 s
        boot B: reported 1, corrected to 3 after 135 s
    So no fixed settle window is safe -- an earlier version of this function
    waited 45 s, decided "stable", and still wrote the wrong profile on boot B.

    Instead we ignore chip->state at boot and decide from the raw sensors, which
    /proc/tristatekey/hall_data re-measures on every read. position_from_hall()
    is the driver's own reboot_get_position() rule, so this is exactly the
    decision the driver would have made had its data been ready.

    We wait for two consecutive agreeing readings, then act. If the sensors
    never produce usable data we return None and write nothing at all:
    AccountsService persists the ringer profile across reboots and the switch
    rarely moves while the phone is off, so leaving the stored profile alone is
    much safer than guessing.
    """
    deadline = time.time() + SETTLE_SECS
    prev = None
    while time.time() < deadline:
        hall = read_hall_data()
        if hall is not None:
            pos = position_from_hall(*hall)
            if pos == prev and pos in mapping:
                log("hall data %s -> position %d" % (list(hall), pos))
                return pos
            prev = pos
        time.sleep(1)
    log("no usable hall data after %ds; leaving stored profile alone"
        % SETTLE_SECS)
    return None


def read_current_position():
    try:
        with open(STATE_PROC) as fh:
            return int(fh.read().strip())
    except (OSError, ValueError):
        return None


def main():
    mapping = load_map()

    dev = find_device()
    if dev is None:
        log("alert slider input device (%s) not found" % DEVNAME)
        return 1
    log("alert slider on %s" % dev)

    # Decide the boot position from the raw sensors, not from the driver's
    # cached answer. See settle_initial_position().
    pos = settle_initial_position(mapping)
    if pos is not None:
        apply_profile(mapping[pos])

    # If we never got a trustworthy reading, last stays None and the loop below
    # will apply the first valid position it sees.
    last = pos

    # chip->state can still be stale for minutes after we have already worked
    # out the true position (measured: 135 s on one boot). If we started
    # trusting it immediately we would read the stale value, see it differ from
    # what we just applied, and promptly re-apply the wrong profile -- undoing
    # the fix above. So until the driver's own answer agrees with the sensors at
    # least once, we keep deciding from the hall data; after that the driver has
    # caught up and we defer to it, because its runtime path
    # (interf_get_position) is calibrated and compensates for interference,
    # which the coarse boot rule does not.
    driver_trusted = pos is None
    poller = select.poll()
    # O_NONBLOCK is load-bearing: the drain loop below relies on the final
    # read() raising BlockingIOError once the queue is empty. Without it, a
    # burst of switch chatter (measured: dozens of value=1/0 pairs in under a
    # second while the slider is mid-move) gets drained one event at a time,
    # and the read() call after the very last one just blocks -- forever,
    # since nothing else will wake it -- skipping the /proc check below on
    # every iteration from then on. That is exactly what happened on the
    # first real-world test: the daemon sat in evdev_read from the moment the
    # switch chattered until it was noticed and restarted.
    fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, "rb", buffering=0) as fh:
        poller.register(fh.fileno(), select.POLLIN)
        while True:
            # Wake on an event, or every 2 s regardless. Either way the decision
            # below is made from /proc, never from the event value.
            poller.poll(POLL_MS)

            # Drain whatever is queued so the fd does not stay readable.
            # This never blocks: the fd is non-blocking, so the read that
            # finds nothing left raises BlockingIOError immediately.
            try:
                while True:
                    data = fh.read(EVENT_SIZE)
                    if not data or len(data) < EVENT_SIZE:
                        break
                    _, _, etype, code, value = struct.unpack(EVENT_FMT, data)
                    if etype == EV_KEY and code == KEY_F3 and DEBUG:
                        log("evdev: KEY_F3 value=%d" % value)
            except BlockingIOError:
                pass

            if driver_trusted:
                pos = read_current_position()
            else:
                # Still waiting for chip->state to catch up with reality.
                hall = read_hall_data()
                pos = position_from_hall(*hall) if hall else None
                if pos is not None and read_current_position() == pos:
                    log("driver agrees with hall data (%d); using tri_state" % pos)
                    driver_trusted = True

            if pos is None or pos not in mapping or pos == last:
                continue
            last = pos
            apply_profile(mapping[pos])
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass
