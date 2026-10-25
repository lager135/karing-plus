"""Read and edit the user domain list that zapret strategies actually load.

Strategies read lists/list-general-user.txt (see --hostlist= in the .bat files).
The file must never be left empty, so the placeholder line stays.
"""
from pathlib import Path

PLACEHOLDER = "domain.example.abc"


def read_domains(list_path: Path):
    if not list_path.exists():
        return []
    domains = []
    with open(list_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and line != PLACEHOLDER:
                domains.append(line.lower())
    return domains


def add_domains(list_path: Path, domains):
    """Append domains that are not in the file yet. Existing lines are kept as they are."""
    existing = set()
    if list_path.exists():
        with open(list_path, encoding="utf-8") as f:
            existing = {line.strip().lower() for line in f}
    missing = []
    for domain in domains:
        domain = domain.lower()
        if domain not in existing:
            existing.add(domain)
            missing.append(domain)
    if not missing:
        return 0
    list_path.parent.mkdir(parents=True, exist_ok=True)
    with open(list_path, "a", encoding="utf-8") as f:
        for domain in missing:
            f.write(domain + "\n")
    return len(missing)


def remove_domains(list_path: Path, domains):
    """Remove the given domains. The placeholder line is kept so the file is never empty."""
    if not list_path.exists():
        return 0
    targets = {d.lower() for d in domains}
    with open(list_path, encoding="utf-8") as f:
        lines = f.readlines()
    kept = [line for line in lines if line.strip().lower() not in targets]
    removed = len(lines) - len(kept)
    if not any(line.strip() == PLACEHOLDER for line in kept):
        kept.append(PLACEHOLDER + "\n")
    with open(list_path, "w", encoding="utf-8") as f:
        f.writelines(kept)
    return removed
