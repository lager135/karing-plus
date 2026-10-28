import os
"""Platform abstraction for zapret bundles."""
from pathlib import Path
import platform
import subprocess
import sys

class ZapretPlatform:
    def name(self): return platform.system()
    def is_supported(self): return True
    def list_strategies(self, zapret_dir: Path): return []
    def start(self, strategy, zapret_dir): return False, "platform runner not configured"
    def stop(self): return None
    def is_running(self): return False


# --- Karing+ mode ---------------------------------------------------------------------------------
# Inside Karing+ (ZAPRET_KARING=1) the PC may also run the VPN with a TUN adapter. winws would then see
# the TUN traffic too and inject its fake packets into the tunnel, and its wide ipset could hit the VPN
# server. So the strategy is started from a copy that limits winws to the physical adapter and excludes
# the VPN server addresses (lists/ipset-exclude-karing.txt, written by the Karing+ service).

KARING_EXCLUDE = "ipset-exclude-karing.txt"
_VIRTUAL = ("sing-tun", "wintun", "wireguard", "tap-", "tunnel", "meta", "tailscale", "radmin",
            "hyper-v", "virtual", "vpn", "loopback")


def _physical_ifindex():
    """Index of the adapter with the default route that is not a VPN/TUN/virtual adapter, or None."""
    script = (
        "$a = Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object { @{ i=$_.ifIndex; d=$_.InterfaceDescription; n=$_.Name } };"
        "Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } |"
        " ForEach-Object { $r=$_; $x = $a | Where-Object { $_.i -eq $r.ifIndex }; if ($x) { '{0}|{1}|{2}' -f $x.i, $x.d, $x.n } }"
    )
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
                             capture_output=True, text=True, timeout=15,
                             creationflags=subprocess.CREATE_NO_WINDOW).stdout
    except Exception:
        return None
    for line in out.splitlines():
        parts = line.strip().split("|")
        if len(parts) < 3 or not parts[0].isdigit():
            continue
        desc = (parts[1] + " " + parts[2]).lower()
        if any(v in desc for v in _VIRTUAL):
            continue
        return int(parts[0])
    return None


def _karing_variant(bat: Path, zapret_dir: Path) -> Path:
    """Writes service_kp_run.bat (not listed as a strategy): the strategy with --wf-iface and the exclude list."""
    lists = zapret_dir / "lists"
    exclude = lists / KARING_EXCLUDE
    if not exclude.exists():
        # TEST-NET placeholder so the file is never empty.
        exclude.write_text("203.0.113.255/32\n", encoding="utf-8")
    exc = f'--ipset-exclude="%LISTS%{KARING_EXCLUDE}"'
    lines = bat.read_text(encoding="utf-8", errors="replace").splitlines()
    start = next((i for i, l in enumerate(lines) if 'winws.exe"' in l), None)
    if start is None:
        return bat
    iface = _physical_ifindex()
    i = start
    while i < len(lines):
        line = lines[i]
        cont = line.rstrip().endswith("^")
        if i == start and iface is not None:
            line = line.replace('winws.exe"', f'winws.exe" --wf-iface={iface}', 1)
        if " --new ^" in line:
            line = line.replace(" --new ^", f" {exc} --new ^")
        elif not cont:
            line = line.rstrip() + f" {exc}"
        lines[i] = line
        if not cont:
            break
        i += 1
    out = zapret_dir / "service_kp_run.bat"
    out.write_text("\r\n".join(lines) + "\r\n", encoding="utf-8")
    return out


class WindowsPlatform(ZapretPlatform):
    def name(self): return "Windows"
    def is_supported(self): return sys.platform == "win32"
    def _bin_path(self, zapret_dir, name): return zapret_dir / "bin" / name
    def start(self, strategy, zapret_dir):
        # Only a strategy from the list: the name must not point outside zapret_dir.
        if strategy not in self.list_strategies(zapret_dir):
            return False, "unknown strategy"
        bat = zapret_dir / f"{strategy}.bat"
        if not bat.exists(): return False, f"strategy {strategy}.bat not found"
        # A second winws on the same traffic breaks bypass: stop ours before starting a strategy.
        try:
            from core.blockcheck import kill_all_winws
            kill_all_winws()
        except Exception: pass
        if os.environ.get("ZAPRET_KARING") == "1":
            try:
                bat = _karing_variant(bat, zapret_dir)
            except Exception:
                pass
        try:
            # CREATE_NO_WINDOW: a console window here showed up as an empty cmd. Same flag blockcheck uses.
            subprocess.Popen(["cmd", "/c", str(bat)], cwd=str(zapret_dir),
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             creationflags=subprocess.CREATE_NO_WINDOW)
            return True, "started"
        except Exception as exc: return False, str(exc)
    def stop(self):
        # Only winws started from this backend's zapret folder; another zapret copy keeps running.
        try:
            import psutil
            from core.blockcheck import _is_ours
            for process in psutil.process_iter(["name"]):
                if (process.info["name"] or "").lower() == "winws.exe" and _is_ours(process):
                    try: process.terminate()
                    except Exception: pass
        except Exception: pass
    def is_running(self):
        try:
            import psutil
            from core.blockcheck import _is_ours
            return any((p.info["name"] or "").lower() == "winws.exe" and _is_ours(p) for p in psutil.process_iter(["name"]))
        except Exception: return False
    def list_strategies(self, zapret_dir):
        return sorted(f.stem for f in zapret_dir.glob("*.bat") if not f.stem.lower().startswith("service"))

def get_platform():
    if sys.platform == "win32":
        return WindowsPlatform()
    if sys.platform.startswith("linux"):
        from core.platforms.linux import LinuxPlatform
        return LinuxPlatform()
    return ZapretPlatform()
