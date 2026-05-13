#!/usr/bin/env python3
"""
Diagnostic for UDP egress, NAT semantics, and vendor relay reachability.

Used by the stable-egress verification loop in
docs/plans/app-stable-egress-v2-plan.md (eve-horizon-2). Copy into a pod and run:

    kubectl -n <ns> cp scripts/stable-egress/udp-diag.py <pod>:/tmp/udp-diag.py -c <container>
    kubectl -n <ns> exec <pod> -c <container> -- python3 /tmp/udp-diag.py

Reads cleanly:
  - "egress public IP" — what the rest of the Internet sees
  - DNS over UDP/53 — proves UDP egress works at all
  - STUN binding from a SINGLE local socket across multiple servers — same
    external (IP, port) across servers proves endpoint-independent NAT (good);
    different external ports while reusing one local socket prove
    address-and-port-dependent / symmetric NAT (bad for hole-punching protocols)
  - vendor UDP probes — non-zero reply within a few seconds means the relay
    accepts our packets; TIMEOUT is the symptom we're trying to fix
"""

import socket, struct, secrets, urllib.request, time

STUN_SERVERS = [
    ("stun.l.google.com", 19302),
    ("stun1.l.google.com", 19302),
    ("stun.cloudflare.com", 3478),
]

VENDOR_RELAYS = [
    ("us-3.iotcplatform.com", 32100),
    ("eu-3.iotcplatform.com", 32100),
    ("vuid.eye4.cn", 32100),
]


def egress_ip():
    try:
        return urllib.request.urlopen("https://api.ipify.org", timeout=8).read().decode().strip()
    except Exception as e:
        return f"ERR {e}"


def udp_dns(server="1.1.1.1"):
    q = bytes.fromhex("abcd0100000100000000000007") + b"example" + b"\x03com\x00" + bytes.fromhex("00010001")
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5)
    t0 = time.time()
    try:
        s.sendto(q, (server, 53)); data, _ = s.recvfrom(4096)
        return f"OK ({len(data)}B in {(time.time()-t0)*1000:.0f}ms)"
    except Exception as e:
        return f"FAIL {e}"
    finally:
        s.close()


def parse_stun_response(data):
    """Parse a STUN binding response. Returns mapped (ip, port) or None."""
    if len(data) < 20:
        return None
    _, msg_len, _ = struct.unpack("!HHI", data[:8])
    i = 20
    mapped = None
    while i + 4 <= 20 + msg_len:
        atype, alen = struct.unpack("!HH", data[i:i+4])
        val = data[i+4:i+4+alen]
        if atype == 0x0020 and len(val) >= 8:
            # XOR-MAPPED-ADDRESS — preferred (RFC 5389)
            xport = struct.unpack("!H", val[2:4])[0] ^ (0x2112A442 >> 16)
            xip = bytes(b ^ m for b, m in zip(val[4:8], struct.pack("!I", 0x2112A442)))
            return (".".join(str(b) for b in xip), xport)
        if atype == 0x0001 and len(val) >= 8 and not mapped:
            # MAPPED-ADDRESS fallback
            mport = struct.unpack("!H", val[2:4])[0]
            mip = ".".join(str(b) for b in val[4:8])
            mapped = (mip, mport)
        i += 4 + ((alen + 3) & ~3)
    return mapped


def stun_probe_shared(sock, host, port):
    """Send a STUN binding request from `sock` and read the reply. Returns ('OK'|'FAIL ...', mapped|None)."""
    txn = secrets.token_bytes(12)
    pkt = struct.pack("!HHI", 0x0001, 0, 0x2112A442) + txn
    try:
        sock.sendto(pkt, (host, port))
        data, _ = sock.recvfrom(2048)
    except Exception as e:
        return f"FAIL {e}", None
    return "OK", parse_stun_response(data)


def classify_nat(mappings):
    """mappings: list of (host, port, mapped). mapped is (ip, port) or None.

    Returns one of:
      - 'endpoint-independent (good)' if all successful mappings share the same (ip, port)
      - 'address/port-dependent (bad for hole-punching)' if external ports differ across servers
      - 'inconclusive' otherwise
    """
    successes = [m for *_rest, m in mappings if m is not None]
    if len(successes) < 2:
        return "inconclusive"
    first = successes[0]
    if all(m == first for m in successes):
        return "endpoint-independent (good)"
    ips = {m[0] for m in successes}
    ports = {m[1] for m in successes}
    if len(ports) > 1:
        return "address/port-dependent (bad for hole-punching)"
    if len(ips) > 1:
        return "address-dependent (also bad)"
    return "inconclusive"


def udp_relay_probe(ip, port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
    try:
        s.sendto(b"\x00\x00\x00\x00\x00\x00", (ip, port)); data, _ = s.recvfrom(2048)
        return f"OK reply {len(data)}B"
    except socket.timeout:
        return "TIMEOUT (no reply 3s)"
    except Exception as e:
        return f"FAIL {e}"
    finally:
        s.close()


print("=== egress public IP (TCP) ===")
print(" ", egress_ip())

print("\n=== UDP egress: DNS query (UDP/53) ===")
print(" ", "1.1.1.1 ->", udp_dns("1.1.1.1"))
print(" ", "8.8.8.8 ->", udp_dns("8.8.8.8"))

print("\n=== STUN binding from a SHARED local UDP socket ===")
print("  (same external port across servers => endpoint-independent NAT)")
shared = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
shared.bind(("0.0.0.0", 0))
shared.settimeout(5)
local_ip, local_port = shared.getsockname()
print(f"  local socket bound to {local_ip}:{local_port}")
mappings = []
try:
    for host, port in STUN_SERVERS:
        st, m = stun_probe_shared(shared, host, port)
        mappings.append((host, port, m))
        print(f"  {host}:{port} -> {st} mapped={m}")
finally:
    shared.close()
print(f"  classification: {classify_nat(mappings)}")

print("\n=== UDP probe to camera relay (vendor) hosts ===")
for h, p in VENDOR_RELAYS:
    try:
        ip = socket.gethostbyname(h)
    except Exception as e:
        print(f"  {h}: DNS fail {e}"); continue
    print(f"  {h} ({ip}):{p} -> {udp_relay_probe(ip, p)}")
