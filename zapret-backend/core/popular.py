"""Collect domains of popular services from public zapret lists, at most MAX_DOMAINS of them."""
import re
from pathlib import Path
from urllib.request import Request, urlopen

from .aibypass.domains import AI_DOMAINS
from .presets import APP_PRESETS
from .userlist import add_domains

MAX_DOMAINS = 250

# Public lists that already contain blocked domains (same sources as AI Bypass).
SOURCES = sorted({info["source"] for info in AI_DOMAINS.values() if info.get("source")})

DOMAIN_RE = re.compile(r"^(?:[a-z0-9-]+\.)+[a-z]{2,}$")


def popular_keywords():
    """Base names of popular services: youtube, discord, ..., plus AI service names."""
    words = set(APP_PRESETS.keys())
    words.update(key for key in AI_DOMAINS.keys())
    return words


def fetch(url, timeout=15):
    req = Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urlopen(req, timeout=timeout) as response:
        return response.read().decode("utf-8", errors="ignore")


def extract_domains(text):
    """Pull plain domain names out of list or hosts-style text."""
    found = []
    for raw in text.splitlines():
        line = raw.strip().lstrip("^").split("#")[0].strip()
        if not line:
            continue
        parts = line.split()
        candidate = parts[-1] if len(parts) > 1 else parts[0]
        candidate = candidate.lower().strip(".")
        if DOMAIN_RE.match(candidate):
            found.append(candidate)
    return found


def is_popular(domain, keywords):
    return any(word in domain for word in keywords)


def collect(sources=None):
    """Download sources, keep popular-service domains, return at most MAX_DOMAINS unique entries."""
    keywords = popular_keywords()
    seen = set()
    picked = []
    errors = []
    for url in (sources or SOURCES):
        try:
            text = fetch(url)
        except Exception as exc:
            errors.append(f"{url}: {exc}")
            continue
        for domain in extract_domains(text):
            if domain in seen or not is_popular(domain, keywords):
                continue
            seen.add(domain)
            picked.append(domain)
            if len(picked) >= MAX_DOMAINS:
                return picked, errors
    return picked, errors


def update_user_list(zapret_dir):
    """Collect popular domains and append them to the list strategies read. Returns a short report."""
    picked, errors = collect()
    list_path = Path(zapret_dir) / "lists" / "list-general-user.txt"
    added = add_domains(list_path, picked)
    return {"found": len(picked), "added": added, "limit": MAX_DOMAINS, "errors": errors}
