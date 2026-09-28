#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3
require_command dbus-daemon

grep -Fx 'ExecStart=/usr/bin/omarchy-bluetooth-agent' "$ROOT/default/systemd/user/bt-agent.service" >/dev/null ||
  fail "bt-agent.service runs the Omarchy agent"
grep -F 'os.execv("/usr/bin/bt-agent", ["bt-agent", "-c", "NoInputNoOutput"])' "$ROOT/bin/omarchy-bluetooth-agent" >/dev/null ||
  fail "without the toggle, pairing stays the auto-accepting bt-agent"
pass "bt-agent.service keeps auto-accept pairing unless the prompt toggle is on"

# The agent runs against a private bus standing in for the system bus, a fake
# BlueZ that calls it the way bluetoothd would, and stand-ins for the menu and
# notification helpers, so nothing here touches the real adapter.
TEST_DIR=$(mktemp -d)
BUS_PID=
trap '[[ -n $BUS_PID ]] && kill "$BUS_PID" 2>/dev/null; rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/home/.local/state/omarchy/toggles" "$TEST_DIR/bin"
touch "$TEST_DIR/home/.local/state/omarchy/toggles/bluetooth-prompt"

# Menu stand-ins answer with the contents of $TEST_DIR/answer, or wait to be
# hidden when it says "wait", the way the real helpers wait on their menu.
for helper in omarchy-menu-select omarchy-menu-input; do
  cat >"$TEST_DIR/bin/$helper" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_DIR/prompts"
answer=$(<"$TEST_DIR/answer")
if [[ $answer == "wait" ]]; then
  while [[ -d $TEST_DIR && ! -e $TEST_DIR/hidden ]]; do sleep 0.05; done
  exit 1
fi
printf '%s\n' "$answer"
EOF
done
cat >"$TEST_DIR/bin/omarchy-notification-send" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_DIR/notifications"
echo 7
EOF
cat >"$TEST_DIR/bin/omarchy-shell" <<'EOF'
#!/bin/bash
[[ $* == "shell hide omarchy.menu" ]] && touch "$TEST_DIR/hidden"
EOF
chmod +x "$TEST_DIR/bin/"*

read -r BUS_ADDRESS BUS_PID < <(dbus-daemon --session --fork --print-address=1 --print-pid=1 | paste -sd ' ')

export TEST_DIR
DBUS_SYSTEM_BUS_ADDRESS=$BUS_ADDRESS PATH="$TEST_DIR/bin:$PATH" HOME="$TEST_DIR/home" \
  timeout 30s python3 - "$ROOT/bin/omarchy-bluetooth-agent" <<'PY' || fail "the pairing agent answers BlueZ requests"
import os
import subprocess
import sys
import threading

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

test_dir = os.environ["TEST_DIR"]
device = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
loop = GLib.MainLoop()
registered = threading.Event()
agent = {}

bluez = Gio.DBusNodeInfo.new_for_xml("""
<node>
  <interface name="org.bluez.AgentManager1">
    <method name="RegisterAgent"><arg type="o"/><arg type="s"/></method>
    <method name="RequestDefaultAgent"><arg type="o"/></method>
  </interface>
  <interface name="org.freedesktop.DBus.Properties">
    <method name="Get"><arg type="s"/><arg type="s"/><arg type="v" direction="out"/></method>
  </interface>
</node>""")


def on_call(connection, sender, path, interface, method, params, invocation):
    if method == "RegisterAgent":
        agent.update(name=sender, path=params[0], capability=params[1])
        invocation.return_value(None)
    elif method == "RequestDefaultAgent":
        invocation.return_value(None)
        registered.set()
    else:
        invocation.return_value(GLib.Variant("(v)", (GLib.Variant("s", "Test Keyboard"),)))


bus.register_object_with_closures2("/org/bluez", bluez.interfaces[0], on_call, None, None)
bus.register_object_with_closures2(device, bluez.interfaces[1], on_call, None, None)
Gio.bus_own_name_on_connection(bus, "org.bluez", Gio.BusNameOwnerFlags.NONE, None, None)

proc = subprocess.Popen([sys.argv[1]])


def call(method, signature, *args, reply=None):
    caller = Gio.DBusConnection.new_for_address_sync(
        os.environ["DBUS_SYSTEM_BUS_ADDRESS"],
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    try:
        result = caller.call_sync(agent["name"], agent["path"], "org.bluez.Agent1", method,
                                  GLib.Variant(signature, args) if signature else None,
                                  GLib.VariantType(reply) if reply else None, Gio.DBusCallFlags.NONE, 10000, None)
        return result.unpack() if reply else "ok"
    except GLib.Error as error:
        return Gio.DBusError.get_remote_error(error)


def answer(text):
    with open(test_dir + "/answer", "w") as file:
        file.write(text)


def read(name):
    try:
        with open(test_dir + "/" + name) as file:
            return file.read()
    except FileNotFoundError:
        return ""


def check(condition, description):
    if not condition:
        print("not ok - " + description, file=sys.stderr)
        os._exit(1)


def scenarios():
    check(registered.wait(10), "agent registers as the default agent")
    check(agent["capability"] == "KeyboardDisplay", "agent registers as KeyboardDisplay so keyboards get a passkey")

    check(call("DisplayPasskey", "(ouq)", device, 4321, 0) == "ok", "DisplayPasskey returns")
    check("Type 004321 on Test Keyboard" in read("notifications"), "the passkey is shown zero-padded with the device name")
    call("DisplayPasskey", "(ouq)", device, 4321, 1)
    check(read("notifications").count("004321") == 1, "keypress updates do not show the passkey again")

    call("DisplayPinCode", "(os)", device, "0000")
    check("Type 0000 on Test Keyboard" in read("notifications"), "the PIN is shown")

    answer("Pair")
    check(call("RequestConfirmation", "(ou)", device, 123456) == "ok", "a confirmed code pairs")
    check("Does Test Keyboard show 123456?" in read("prompts"), "the code to compare is asked about")
    answer("Cancel")
    check(call("RequestConfirmation", "(ou)", device, 123456) == "org.bluez.Error.Rejected", "a declined code is rejected")
    answer("")
    check(call("RequestAuthorization", "(o)", device) == "org.bluez.Error.Rejected", "a dismissed menu is rejected")

    answer("654321")
    check(call("RequestPasskey", "(o)", device, reply="(u)") == (654321,), "a typed passkey is returned")
    answer("12ab")
    check(call("RequestPasskey", "(o)", device, reply="(u)") == "org.bluez.Error.Rejected", "a non-numeric passkey is rejected")
    answer("1234567")
    check(call("RequestPasskey", "(o)", device, reply="(u)") == "org.bluez.Error.Rejected", "a passkey over six digits is rejected")
    answer("abcd")
    check(call("RequestPinCode", "(o)", device, reply="(s)") == ("abcd",), "a typed PIN is returned")

    answer("wait")
    results = []
    waiting = threading.Thread(target=lambda: results.append(call("RequestPinCode", "(o)", device, reply="(s)")))
    waiting.start()
    while read("prompts").count("PIN for") < 2:
        GLib.usleep(50000)
    check(call("Cancel", None) == "ok", "Cancel returns")
    waiting.join(5)
    check(results == ["org.bluez.Error.Rejected"], "Cancel rejects the open question")
    check(os.path.exists(test_dir + "/hidden"), "Cancel closes the menu it opened")

    call("Release", None)
    check(proc.wait(5) == 1, "Release exits non-zero so systemd registers the agent again")
    GLib.idle_add(loop.quit)


threading.Thread(target=scenarios, daemon=True).start()
loop.run()
PY
pass "the pairing agent shows codes, asks through the menu, and handles Cancel"
