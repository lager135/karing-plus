"""Find the domains of a service by its name: root domains from certificate transparency (crt.sh)."""
import json
import re
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import quote
from urllib.request import Request, urlopen

from .presets import APP_PRESETS

MAX_DOMAINS = 250
TLDS = ["com", "net", "org", "io", "tv", "app", "me", "ru", "gg"]
DOMAIN_RE = re.compile(r"^(?:[a-z0-9-]+\.)+[a-z]{2,}$")


def fetch_crtsh(root, timeout=25):
    """All names that certificates were issued for under the root (wildcards removed)."""
    url = f"https://crt.sh/?q={quote('%.' + root)}&output=json"
    req = Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urlopen(req, timeout=timeout) as response:
        rows = json.loads(response.read().decode("utf-8", errors="ignore") or "[]")
    names = set()
    for row in rows:
        for name in str(row.get("name_value", "")).split("\n"):
            name = name.strip().lower().lstrip("*.").strip(".")
            if name and DOMAIN_RE.match(name):
                names.add(name)
    return names


def keep_under(root, names):
    """Only root itself and its real subdomains, so youtube.com.ar or youtube.co.uk are dropped."""
    return {n for n in names if n == root or n.endswith("." + root)}


def guess_roots(query):
    """Turn a service name into candidate root domains, e.g. 'Discord' -> discord.com, discord.gg, ..."""
    slug = re.sub(r"[^a-z0-9-]", "", query.lower().replace(" ", ""))
    if not slug:
        return []
    if "." in query:
        return [query.lower().strip()]
    return [f"{slug}.{tld}" for tld in TLDS]


def search(query):
    """Return {'query', 'roots', 'domains', 'preset'} without changing anything on disk."""
    query = query.strip()
    candidates = guess_roots(query)
    roots = []

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(_safe_fetch, candidates))

    # A lookup that failed (timeout, crt.sh down) is reported, not silently read as "no such domain".
    failed = [root for root, names in zip(candidates, results) if names is None]
    for root, names in zip(candidates, results):
        found = keep_under(root, names or set())
        if found:
            # Shorter names are more general (root, then first-level subdomains), so they come first.
            ordered = sorted(found, key=lambda n: (n.count("."), len(n), n))[:MAX_DOMAINS]
            roots.append({"root": root, "count": len(found), "domains": ordered})

    # Curated preset (if the name matches a known service) goes first: it has the related CDN domains too.
    preset_key = _match_preset(query)
    preset_domains = list(APP_PRESETS[preset_key]["domains"]) if preset_key else []
    # The user picks which roots to add: different companies can share a name (e.g. telegram.io vs telegram.org).
    return {"query": query, "roots": roots, "preset": preset_key, "preset_domains": preset_domains,
            "limit": MAX_DOMAINS, "failed": failed}


def _safe_fetch(root):
    # crt.sh is slow for big domains (steam.com takes over 25 s) and sometimes drops a request: one retry.
    for _ in range(2):
        try:
            return fetch_crtsh(root, timeout=70)
        except Exception:
            continue
    return None


def _match_preset(query):
    q = query.lower().replace(" ", "")
    for key, info in APP_PRESETS.items():
        if q == key or q in key or key in q:
            return key
    return None
