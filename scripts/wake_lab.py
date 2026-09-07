#!/usr/bin/env python3
"""Wake the lab server from suspend with a Wake-on-LAN magic packet.

    scripts/wake_lab.py [--mac MAC] [--broadcast ADDR]

The box suspends overnight and wakes on an RTC alarm at 17:00. This is how you
get it back before then. Run it from any machine on the LAN; nothing needs to
be installed on the sender.

Sends to the subnet BROADCAST, not to lab's address: a suspended host has no
ARP entry, so a unicast packet has nowhere to be delivered. Port 9 is the
convention; 7 is sent too because some NICs only listen there.

Measured: sshd answered 12s after the packet.
"""

import argparse
import socket
import sys

# enp5s0. The second NIC (enp6s0f1) is unused -- waking the wrong one would
# look correct here and never bring the box up.
LAB_MAC = "24:4b:fe:df:7f:9c"
BROADCAST = "192.168.1.255"
PORTS = (9, 7)


def magic_packet(mac: str) -> bytes:
    """Six 0xFF bytes, then the target MAC repeated sixteen times."""
    clean = mac.replace(":", "").replace("-", "")
    if len(clean) != 12:
        raise ValueError(f"expected a 6-byte MAC, got {mac!r}")
    return b"\xff" * 6 + bytes.fromhex(clean) * 16


def wake(mac: str, broadcast: str) -> None:
    packet = magic_packet(mac)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for port in PORTS:
            sock.sendto(packet, (broadcast, port))
            print(f"sent magic packet for {mac} to {broadcast}:{port}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--mac", default=LAB_MAC, help=f"target MAC (default {LAB_MAC})")
    parser.add_argument(
        "--broadcast", default=BROADCAST, help=f"broadcast address (default {BROADCAST})"
    )
    args = parser.parse_args()

    try:
        wake(args.mac, args.broadcast)
    except (OSError, ValueError) as exc:
        print(f"failed to send: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
