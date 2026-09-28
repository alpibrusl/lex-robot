#!/usr/bin/env python3
"""A mock miio device, so the Lex miio client is testable with no vacuum.

Speaks the wire protocol a Xiaomi Robot Vacuum X10 (`dreame.vacuum.r2209`,
retail B102GL) speaks, well enough to exercise every branch of the client:

    32-byte header, big-endian
      0..2    magic 0x2131
      2..4    total packet length
      4..8    unknown (0 in requests, echoed 0 by devices)
      8..12   device id
      12..16  stamp (device uptime seconds)
      16..32  MD5 checksum over the packet with the token in this field
    32..      AES-128-CBC(payload), key = MD5(token), iv = MD5(key + token)

The handshake is the same header with length 0x20, device id / stamp /
checksum all 0xff and no payload. It is UNENCRYPTED, which is why device
discovery works without the token and control does not.

Commands are MIoT-spec, which is what this generation of Dreame uses
instead of the older `app_start` verbs:

    get_properties [{did, siid, piid}]     -> [{did, siid, piid, value, code}]
    set_properties [{did, siid, piid, value}]
    action         {did, siid, aiid, in}

The published map for r2209 — the whole surface the sidecar needs:

    status       siid 2 piid 1   1=sweeping 2=standby 3=paused
                                 5=returning 6=charging 13=charged
    battery      siid 3 piid 1   0..100
    start-sweep  siid 2 aiid 1
    stop-sweep   siid 2 aiid 2
    dock         siid 3 aiid 1

Run standalone (defaults to the real miio port):

    python3 sidecar/mock_miio.py [port]
"""

import hashlib
import json
import socket
import struct
import sys
import threading
import time

MAGIC = 0x2131
HELLO = bytes.fromhex("21310020" + "ff" * 28)
TOKEN = bytes.fromhex("00112233445566778899aabbccddeeff")
DEVICE_ID = 0x0BADF00D

# Vacuum states, in the device's own vocabulary (see module docstring).
SWEEPING, STANDBY, PAUSED, RETURNING, CHARGING = 1, 2, 3, 5, 6


def _key_iv(token: bytes):
    key = hashlib.md5(token).digest()
    return key, hashlib.md5(key + token).digest()


def _pkcs7_pad(b: bytes) -> bytes:
    n = 16 - len(b) % 16
    return b + bytes([n]) * n


def _pkcs7_unpad(b: bytes) -> bytes:
    if not b or len(b) % 16:
        raise ValueError("bad block size")
    n = b[-1]
    if n < 1 or n > 16 or b[-n:] != bytes([n]) * n:
        raise ValueError("bad padding")
    return b[:-n]


def _aes(token: bytes, data: bytes, encrypt: bool) -> bytes:
    """AES-128-CBC without a crypto dependency.

    Implemented here rather than pulled in so the test harness stays
    stdlib-only, matching every other sidecar in this repo. It is a
    test double; it is not fast and does not need to be.
    """
    key, iv = _key_iv(token)
    rk = _expand_key(key)
    out, prev = b"", iv
    if encrypt:
        for i in range(0, len(data), 16):
            blk = bytes(a ^ b for a, b in zip(data[i:i + 16], prev))
            prev = _encrypt_block(blk, rk)
            out += prev
    else:
        for i in range(0, len(data), 16):
            blk = data[i:i + 16]
            dec = _decrypt_block(blk, rk)
            out += bytes(a ^ b for a, b in zip(dec, prev))
            prev = blk
    return out


# ── a minimal AES-128 ────────────────────────────────────────────────
_SBOX = bytes.fromhex(
    "637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0"
    "b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b275"
    "09832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cf"
    "d0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2"
    "cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdb"
    "e0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08"
    "ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9e"
    "e1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16")
_INV = [0] * 256
for _i, _v in enumerate(_SBOX):
    _INV[_v] = _i
_RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36]


def _xt(a):  # xtime: multiply by 2 in GF(2^8)
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1


def _mul(a, b):
    r = 0
    for _ in range(8):
        if b & 1:
            r ^= a
        a, b = _xt(a), b >> 1
    return r


def _expand_key(key: bytes):
    w = [list(key[i:i + 4]) for i in range(0, 16, 4)]
    for i in range(4, 44):
        t = list(w[i - 1])
        if i % 4 == 0:
            t = t[1:] + t[:1]
            t = [_SBOX[x] for x in t]
            t[0] ^= _RCON[i // 4 - 1]
        w.append([a ^ b for a, b in zip(w[i - 4], t)])
    return [sum(w[r * 4:(r + 1) * 4], []) for r in range(11)]


def _encrypt_block(b: bytes, rk):
    s = [x ^ y for x, y in zip(b, rk[0])]
    for rnd in range(1, 11):
        s = [_SBOX[x] for x in s]
        s = [s[(i + 4 * (i % 4)) % 16] for i in range(16)]
        if rnd != 10:
            n = []
            for c in range(4):
                col = s[c * 4:c * 4 + 4]
                n += [_mul(col[0], 2) ^ _mul(col[1], 3) ^ col[2] ^ col[3],
                      col[0] ^ _mul(col[1], 2) ^ _mul(col[2], 3) ^ col[3],
                      col[0] ^ col[1] ^ _mul(col[2], 2) ^ _mul(col[3], 3),
                      _mul(col[0], 3) ^ col[1] ^ col[2] ^ _mul(col[3], 2)]
            s = n
        s = [x ^ y for x, y in zip(s, rk[rnd])]
    return bytes(s)


def _decrypt_block(b: bytes, rk):
    s = [x ^ y for x, y in zip(b, rk[10])]
    for rnd in range(9, -1, -1):
        s = [s[(i - 4 * (i % 4)) % 16] for i in range(16)]
        s = [_INV[x] for x in s]
        s = [x ^ y for x, y in zip(s, rk[rnd])]
        if rnd:
            n = []
            for c in range(4):
                col = s[c * 4:c * 4 + 4]
                n += [_mul(col[0], 14) ^ _mul(col[1], 11) ^ _mul(col[2], 13) ^ _mul(col[3], 9),
                      _mul(col[0], 9) ^ _mul(col[1], 14) ^ _mul(col[2], 11) ^ _mul(col[3], 13),
                      _mul(col[0], 13) ^ _mul(col[1], 9) ^ _mul(col[2], 14) ^ _mul(col[3], 11),
                      _mul(col[0], 11) ^ _mul(col[1], 13) ^ _mul(col[2], 9) ^ _mul(col[3], 14)]
            s = n
    return bytes(s)


# ── the device ───────────────────────────────────────────────────────
class MockVacuum:
    def __init__(self, token=TOKEN, device_id=DEVICE_ID, port=54321):
        self.token = token
        self.device_id = device_id
        self.port = port
        self.status = CHARGING
        self.battery = 100
        self.requests = []          # decoded, for tests to assert on
        self.reject_checksum = False
        self._sock = None
        self._t = None
        self._stop = False
        self._t0 = time.time()

    # -- framing --
    def _stamp(self):
        return int(time.time() - self._t0) & 0xFFFFFFFF

    def _pack(self, payload: bytes) -> bytes:
        body = _aes(self.token, _pkcs7_pad(payload), True) if payload else b""
        head = struct.pack(">HHII I".replace(" ", ""), MAGIC, 32 + len(body),
                           0, self.device_id, self._stamp())
        digest = hashlib.md5(head + self.token + body).digest()
        return head + digest + body

    def _unpack(self, pkt: bytes):
        head, digest, body = pkt[:16], pkt[16:32], pkt[32:]
        expect = hashlib.md5(head + self.token + body).digest()
        if digest != expect:
            raise ValueError("checksum mismatch")
        return json.loads(_pkcs7_unpad(_aes(self.token, body, False)))

    # -- MIoT --
    def _prop(self, siid, piid):
        if (siid, piid) == (2, 1):
            return self.status
        if (siid, piid) == (3, 1):
            return self.battery
        return None

    def _dispatch(self, req):
        method, params = req.get("method"), req.get("params")
        if method == "get_properties":
            out = []
            for p in params:
                v = self._prop(p["siid"], p["piid"])
                out.append({**p, "value": v, "code": 0 if v is not None else -1})
            return {"id": req["id"], "result": out}
        if method == "action":
            siid, aiid = params["siid"], params["aiid"]
            if (siid, aiid) == (2, 1):
                self.status = SWEEPING
            elif (siid, aiid) == (2, 2):
                self.status = STANDBY
            elif (siid, aiid) == (3, 1):
                self.status = RETURNING
            else:
                return {"id": req["id"], "error": {"code": -1,
                                                   "message": "unknown action"}}
            return {"id": req["id"], "result": {"code": 0}}
        if method == "miIO.info":
            return {"id": req["id"], "result": {"model": "dreame.vacuum.r2209"}}
        return {"id": req["id"], "error": {"code": -1, "message": "unknown method"}}

    # -- serve --
    def _serve(self):
        while not self._stop:
            try:
                data, addr = self._sock.recvfrom(65535)
            except OSError:
                return
            if len(data) < 32 or struct.unpack(">H", data[:2])[0] != MAGIC:
                continue
            if data == HELLO or data[4:32] == b"\xff" * 28:
                # Handshake: reply with our id and clock, no payload, and
                # crucially no encryption — this is how a client learns
                # the stamp it must echo before it can talk at all.
                head = struct.pack(">HHIII", MAGIC, 32, 0,
                                   self.device_id, self._stamp())
                self._sock.sendto(head + b"\x00" * 16, addr)
                continue
            try:
                req = self._unpack(data)
            except ValueError:
                # A real device answers a bad checksum with silence, and
                # the client must time out rather than hang.
                continue
            self.requests.append(req)
            self._sock.sendto(self._pack(json.dumps(self._dispatch(req)).encode()), addr)

    def __enter__(self):
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.bind(("127.0.0.1", self.port))
        self.port = self._sock.getsockname()[1]
        self._t = threading.Thread(target=self._serve, daemon=True)
        self._t.start()
        return self

    def __exit__(self, *exc):
        self._stop = True
        if self._sock:
            self._sock.close()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 54321
    with MockVacuum(port=port) as v:
        print(f"mock miio vacuum on 127.0.0.1:{v.port}")
        print(f"  token     {v.token.hex()}")
        print(f"  device id {v.device_id}")
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            pass
