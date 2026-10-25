"""AI Bypass - adds domains to zapret hostlist. Does NOT touch Windows hosts."""
import re
from pathlib import Path
from urllib.request import urlopen, Request
from .domains import AI_DOMAINS


def get_all_domains():
    seen = set()
    result = []
    for info in AI_DOMAINS.values():
        for domain in info["domains"]:
            if domain not in seen:
                seen.add(domain)
                result.append(domain)
    return result


def update_zapret_hostlist(zapret_dir):
    # Strategies read lists/list-general-user.txt. Append only: the user's own lines are never rewritten.
    from ..userlist import add_domains
    hostlist = zapret_dir / "lists" / "list-general-user.txt"
    added = add_domains(hostlist, get_all_domains())
    return True, f"added {added} domains"


def apply_ai_bypass(zapret_dir):
    ok, message = update_zapret_hostlist(zapret_dir)
    return {
        "hosts_ok": True,
        "hosts_msg": "Windows hosts untouched by design",
        "zapret_ok": ok,
        "zapret_msg": message,
    }


if __name__ == "__main__":
    import sys
    zapret_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("zapret")
    print(apply_ai_bypass(zapret_dir))
