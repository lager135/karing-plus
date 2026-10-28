"""Linux runner: the same strategies (*.bat) as on Windows, run with nfqws + nftables.

winws (Windows) and nfqws (Linux) share their desync options. A strategy .bat is parsed into the
winws argument list; the Windows-only packet filter (--wf-tcp/--wf-udp) becomes an nftables rule
that sends those ports to NFQUEUE, and options nfqws does not know are dropped.

Runs as root (inside the Karing+ core service). Traffic of the VPN tunnel and to the VPN servers
(lists/ipset-exclude-karing.txt, written by the service) is left alone.
"""
import os
import re
import shlex
import signal
import subprocess
from pathlib import Path

QNUM = 200
TABLE = "karingplus_zapret"
# nfqws marks the packets it sends itself; they must not loop back into the queue.
# nfqws stays root (--uid=0:0): the service writes the lists with umask 077, so "nobody" could not
# read them.
DESYNC_MARK = "0x40000000"
# Interfaces that are VPN tunnels: zapret must not touch them.
TUNNEL_IFACES = ("tun*", "sing*", "wg*", "utun*", "tap*")
KARING_EXCLUDE = "ipset-exclude-karing.txt"
# Flowseal's game filter is off unless utils/game_filter.enabled exists: port 12 is a dummy.
GAME_FILTER_OFF = "12"


def _bin_dir(zapret_dir: Path) -> Path:
    return zapret_dir / "bin"


def _nfqws(zapret_dir: Path) -> Path:
    return _bin_dir(zapret_dir) / "nfqws"


def _bat_command(bat: Path) -> str:
    """The winws command of a strategy, with ^ line continuations joined."""
    lines = bat.read_text(encoding="utf-8", errors="replace").splitlines()
    start = next((i for i, l in enumerate(lines) if 'winws.exe"' in l), None)
    if start is None:
        raise ValueError("no winws command in " + bat.name)
    parts = []
    for line in lines[start:]:
        cont = line.rstrip().endswith("^")
        parts.append(line.rstrip()[:-1] if cont else line.rstrip())
        if not cont:
            break
    cmd = " ".join(parts)
    return cmd[cmd.index('winws.exe"') + len('winws.exe"'):]


def _game_filter(zapret_dir: Path):
    flag = zapret_dir / "utils" / "game_filter.enabled"
    if not flag.exists():
        return GAME_FILTER_OFF, GAME_FILTER_OFF
    tcp = udp = "1024-65535"
    mode = "all"
    for line in flag.read_text(encoding="utf-8", errors="replace").splitlines():
        key, _, val = line.strip().partition("=")
        key = key.lower()
        if key == "mode" and val:
            mode = val.lower()
        elif key == "tcp" and val:
            tcp = val
        elif key == "udp" and val:
            udp = val
    if mode == "tcp":
        udp = GAME_FILTER_OFF
    elif mode == "udp":
        tcp = GAME_FILTER_OFF
    return tcp, udp


def _supported_options(nfqws: Path, env) -> set:
    out = subprocess.run([str(nfqws), "--help"], capture_output=True, text=True, env=env, timeout=10)
    return set(re.findall(r"^\s*(--[a-z0-9-]+)", out.stdout + out.stderr, re.M))


def _ports(value: str) -> list:
    """'80,443,,12,19294-19344' -> ['80', '443', '12', '19294-19344'] (nft set elements)."""
    return [p.strip() for p in value.split(",") if re.fullmatch(r"\d+(-\d+)?", p.strip())]


def build_args(bat: Path, zapret_dir: Path, supported: set, karing: bool):
    """nfqws arguments and the (tcp, udp) port lists for the nftables rule."""
    game_tcp, game_udp = _game_filter(zapret_dir)
    text = _bat_command(bat)
    subst = {
        "%BIN%": str(_bin_dir(zapret_dir)) + "/",
        "%LISTS%": str(zapret_dir / "lists") + "/",
        "%GameFilterTCP%": game_tcp,
        "%GameFilterUDP%": game_udp,
        "%GameFilter%": game_tcp,
    }
    for k, v in subst.items():
        text = text.replace(k, v)
    # cmd escaping: ^! is a literal "!" (for example --dpi-desync-fake-tls=! = built-in fake).
    text = re.sub(r"\^(.)", r"\1", text)
    tcp, udp, args = [], [], []
    exclude = f"--ipset-exclude={zapret_dir / 'lists' / KARING_EXCLUDE}"
    for tok in shlex.split(text, posix=True):
        if tok.startswith("--wf-tcp="):
            tcp += _ports(tok.split("=", 1)[1])
            continue
        if tok.startswith("--wf-udp="):
            udp += _ports(tok.split("=", 1)[1])
            continue
        opt = tok.split("=", 1)[0]
        if opt.startswith("--wf-") or (supported and opt not in supported):
            continue  # Windows-only or unknown to nfqws
        if tok == "--new" and karing:
            args.append(exclude)
        args.append(tok)
    if karing:
        args.append(exclude)
    return args, tcp, udp


IPT_CHAIN = "KARINGPLUS_ZAPRET"


def _run(cmd, **kw):
    """Runs a firewall tool; a missing tool counts as a failed command, not a crash."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=15, **kw)
    except FileNotFoundError:
        return None


def _has(tool: str) -> bool:
    import shutil
    return shutil.which(tool) is not None


def _nft(script: str):
    subprocess.run(["nft", "-f", "-"], input=script, text=True, check=True, capture_output=True, timeout=15)


def _ipt_ports(ports: list) -> list:
    """nft-style ports -> iptables multiport groups (max 15 entries each, ranges as a:b)."""
    items = [p.replace("-", ":") for p in ports]
    return [",".join(items[i:i + 15]) for i in range(0, len(items), 15)]


def _ipt_up(tcp: list, udp: list):
    for ipt in ("iptables", "ip6tables"):
        if not _has(ipt):
            continue
        run = lambda *a: subprocess.run([ipt, "-t", "mangle", *a], capture_output=True, text=True, timeout=15, check=True)
        run("-N", IPT_CHAIN)
        run("-A", "POSTROUTING", "-j", IPT_CHAIN)
        run("-A", IPT_CHAIN, "-m", "mark", "--mark", f"{DESYNC_MARK}/{DESYNC_MARK}", "-j", "RETURN")
        for iface in TUNNEL_IFACES:
            run("-A", IPT_CHAIN, "-o", iface.replace("*", "+"), "-j", "RETURN")
        for proto, ports in (("tcp", tcp), ("udp", udp)):
            for group in _ipt_ports(ports):
                run("-A", IPT_CHAIN, "-p", proto, "-m", "multiport", "--dports", group,
                    "-m", "connbytes", "--connbytes-dir=original", "--connbytes-mode=packets", "--connbytes", "1:12",
                    "-j", "NFQUEUE", "--queue-num", str(QNUM), "--queue-bypass")


def _ipt_down():
    for ipt in ("iptables", "ip6tables"):
        if not _has(ipt):
            continue
        while (r := _run([ipt, "-t", "mangle", "-D", "POSTROUTING", "-j", IPT_CHAIN])) is not None and r.returncode == 0:
            pass
        _run([ipt, "-t", "mangle", "-F", IPT_CHAIN])
        _run([ipt, "-t", "mangle", "-X", IPT_CHAIN])


def nft_up(tcp: list, udp: list):
    """Sends the strategy's ports to NFQUEUE: nftables when `nft` exists, otherwise iptables."""
    nft_down()
    if not _has("nft"):
        if not _has("iptables"):
            raise RuntimeError("neither nft nor iptables found")
        _ipt_up(tcp, udp)
        return
    skip_ifaces = ", ".join(f'"{i}"' for i in TUNNEL_IFACES)
    rules = [
        f"meta mark and {DESYNC_MARK} != 0 return",
        f"oifname {{ {skip_ifaces} }} return",
    ]
    if tcp:
        rules.append(f"tcp dport {{ {', '.join(tcp)} }} ct original packets 1-12 queue num {QNUM} bypass")
    if udp:
        rules.append(f"udp dport {{ {', '.join(udp)} }} ct original packets 1-12 queue num {QNUM} bypass")
    body = "\n    ".join(rules)
    _nft(f"""table inet {TABLE} {{
  chain post {{
    type filter hook postrouting priority mangle; policy accept;
    {body}
  }}
}}
""")


def nft_down():
    _run(["nft", "delete", "table", "inet", TABLE])
    _ipt_down()


def _own_nfqws_pids(zapret_dir: Path) -> list:
    exe = str(_nfqws(zapret_dir).resolve())
    pids = []
    for d in Path("/proc").iterdir():
        if not d.name.isdigit():
            continue
        try:
            if os.readlink(d / "exe") == exe:
                pids.append(int(d.name))
        except OSError:
            continue
    return pids


class LinuxPlatform:
    def __init__(self):
        self._proc = None

    def name(self):
        return "Linux"

    def is_supported(self):
        return os.geteuid() == 0

    def list_strategies(self, zapret_dir):
        return sorted(f.stem for f in Path(zapret_dir).glob("*.bat") if not f.stem.lower().startswith("service"))

    def start(self, strategy, zapret_dir):
        zapret_dir = Path(zapret_dir)
        # Only a strategy from the list: the name must not point outside zapret_dir.
        if strategy not in self.list_strategies(zapret_dir):
            return False, "unknown strategy"
        nfqws = _nfqws(zapret_dir)
        if not nfqws.exists():
            return False, "nfqws not found"
        if os.geteuid() != 0:
            return False, "zapret needs root (run through the Karing+ service)"
        self.stop()
        env = dict(os.environ, LD_LIBRARY_PATH=str(_bin_dir(zapret_dir)))
        karing = os.environ.get("ZAPRET_KARING") == "1"
        if karing:
            exclude = zapret_dir / "lists" / KARING_EXCLUDE
            if not exclude.exists():
                exclude.write_text("203.0.113.255/32\n", encoding="utf-8")
        try:
            args, tcp, udp = build_args(zapret_dir / f"{strategy}.bat", zapret_dir,
                                        _supported_options(nfqws, env), karing)
            self._proc = subprocess.Popen([str(nfqws), f"--qnum={QNUM}", "--uid=0:0"] + args, cwd=str(zapret_dir),
                                          env=env, stdin=subprocess.DEVNULL,
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                          start_new_session=True)
            nft_up(tcp, udp)
            return True, "started"
        except Exception as exc:
            self.stop()
            return False, str(exc)

    def stop(self):
        nft_down()
        if self._proc is not None and self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=3)
            except Exception:
                self._proc.kill()
        self._proc = None
        # An nfqws left from an earlier backend run of this same folder.
        root = os.environ.get("ZAPRET_ROOT")
        if root:
            for pid in _own_nfqws_pids(Path(root) / "zapret"):
                try:
                    os.kill(pid, signal.SIGTERM)
                except OSError:
                    pass

    def is_running(self):
        return self._proc is not None and self._proc.poll() is None
