"""VPN Gate 목록을 받아 앱과 같은 방식으로 서버 응답을 확인하는 검사 스크립트.

GitHub Actions에서 실행해서, 앱의 목록 해석과 OpenVPN 첫 인사 확인이
실제 서버에서 통하는지 본다.
"""
import base64
import os
import socket
import struct
import time
import urllib.request

API = "https://www.vpngate.net/api/iphone/"


def fetch():
    with urllib.request.urlopen(API, timeout=30) as r:
        text = r.read().decode("utf-8", "replace")
    servers = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("*") or line.startswith("#"):
            continue
        cols = line.split(",")
        if len(cols) < 15 or not cols[-1]:
            continue
        try:
            config = base64.b64decode(cols[-1]).decode("utf-8", "replace")
        except Exception:
            continue
        proto, port, wrapped = "udp", 1194, False
        for raw in config.splitlines():
            parts = raw.strip().split()
            if not parts or parts[0].startswith(("#", ";")):
                continue
            if parts[0] == "proto" and len(parts) > 1:
                proto = "tcp" if parts[1].startswith("tcp") else "udp"
            elif parts[0] == "remote" and len(parts) > 2 and parts[2].isdigit():
                port = int(parts[2])
            elif parts[0] in ("tls-auth", "<tls-auth>") or parts[0].startswith(("tls-crypt", "<tls-crypt")):
                wrapped = True
        servers.append({
            "ip": cols[1], "score": int(cols[2] or 0), "country": cols[6],
            "speed": int(cols[4] or 0), "proto": proto, "port": port, "wrapped": wrapped,
        })
    return servers


def reset_packet(tcp):
    body = bytes([0x38]) + os.urandom(8) + bytes(5)
    return struct.pack(">H", len(body)) + body if tcp else body


def handshake(ip, port, tcp, timeout=4.0):
    """앱의 Probe.openVPNHandshake와 같은 확인. 성공하면 ms, 아니면 None"""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.connect((ip, port))
        t0 = time.time()
        s.send(reset_packet(tcp))
        data = s.recv(4096)
        idx = 2 if tcp else 0
        if len(data) > idx and (data[idx] >> 3) == 8:
            return int((time.time() - t0) * 1000)
        return None
    except Exception:
        return None
    finally:
        s.close()


def tcp_connect(ip, port, timeout=4.0):
    t0 = time.time()
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return int((time.time() - t0) * 1000)
    except Exception:
        return None


def main():
    servers = fetch()
    print(f"VPN Gate 서버 {len(servers)}개 받음")
    by_country = {}
    for s in servers:
        by_country[s["country"]] = by_country.get(s["country"], 0) + 1
    print("국가별:", ", ".join(f"{k} {v}" for k, v in sorted(by_country.items(), key=lambda x: -x[1])[:12]))
    tcp = sum(1 for s in servers if s["proto"] == "tcp")
    print(f"TCP {tcp}개 / UDP {len(servers) - tcp}개 / tls-auth 사용 {sum(s['wrapped'] for s in servers)}개")
    print()

    top = sorted(servers, key=lambda s: -s["score"])[:25]
    ok_hs = ok_tcp = 0
    print(f"{'국가':4} {'IP':16} {'프로토콜':8} {'포트':6} {'OpenVPN응답':12} {'TCP연결':8}")
    for s in top:
        hs = handshake(s["ip"], s["port"], s["proto"] == "tcp")
        tc = tcp_connect(s["ip"], s["port"]) if s["proto"] == "tcp" else None
        ok_hs += hs is not None
        ok_tcp += tc is not None
        print(f"{s['country']:4} {s['ip']:16} {s['proto']:8} {s['port']:<6} "
              f"{(str(hs) + 'ms') if hs is not None else '없음':12} "
              f"{(str(tc) + 'ms') if tc is not None else '-':8}")
    print()
    print(f"점수 상위 {len(top)}개 중 OpenVPN 직접 응답 {ok_hs}개, TCP 포트 열림 {ok_tcp}개")
    print("(GitHub의 미국 서버에서 잰 값이라 한국에서 재면 ms는 달라요)")
    print()
    pool_check()


POOL_BASE = "https://raw.githubusercontent.com/GeorgeXie2333/vpngate-list-mirror/main/"


def pool_check():
    """앱의 PoolAPI와 같은 기준으로 확장 목록을 거르고, '덜 붐비는' 상위 서버에 실제로 인사해 봄"""
    import json
    from datetime import datetime, timezone

    def ts(s):
        return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None

    with urllib.request.urlopen(POOL_BASE + "pool/servers.json", timeout=60) as r:
        data = json.load(r)
    now = datetime.now(timezone.utc)
    kept = []
    for e in data["servers"]:
        if e.get("present_in_latest_source") or not (e.get("config") or {}).get("path"):
            continue
        if e.get("probe_reason") == "tcp":
            p = e.get("tcp_probe") or {}
            ok = ts(p.get("last_success_at"))
            if p.get("status") == "unreachable" or not ok or (now - ok).total_seconds() > 24 * 3600:
                continue
        else:
            seen = ts(e.get("last_seen_at"))
            if not seen or (now - seen).total_seconds() > 48 * 3600:
                continue
        kept.append(e)
    print(f"확장 목록: 전체 {len(data['servers'])}개 중 앱이 쓰는 서버 {len(kept)}개")

    def room(e):
        return (e.get("speed_bps") or 0) / 1e6 / ((e.get("num_vpn_sessions") or 0) + 1)

    top = sorted(kept, key=room, reverse=True)[:12]
    ok = 0
    for e in top:
        with urllib.request.urlopen(POOL_BASE + e["config"]["path"], timeout=30) as r:
            cfg = base64.b64decode(json.load(r)["openvpn_config_base64"]).decode("utf-8", "replace")
        proto, port = "udp", 1194
        for raw in cfg.splitlines():
            parts = raw.strip().split()
            if not parts or parts[0].startswith(("#", ";")):
                continue
            if parts[0] == "proto" and len(parts) > 1:
                proto = "tcp" if parts[1].startswith("tcp") else "udp"
            elif parts[0] == "remote" and len(parts) > 2 and parts[2].isdigit():
                port = int(parts[2])
        hs = handshake(e["ip"], port, proto == "tcp")
        ok += hs is not None
        print(f"{e.get('country_code',''):4} {e['ip']:16} {proto:4} {port:<6} "
              f"{room(e):6.1f} Mbps/명 {e.get('num_vpn_sessions',0):4}명 "
              f"{(str(hs) + 'ms') if hs is not None else '응답 없음'}")
    print(f"덜 붐비는 상위 {len(top)}개 중 OpenVPN 직접 응답 {ok}개")


if __name__ == "__main__":
    main()
