"""Remember recent edits to the user list, so the user can keep them or roll them back.

Every change first copies the list to lists/.history/. Pending entries live in pending.json next to it.
"confirm" forgets the pending entries; "revert" restores the copy taken before the first pending change.
"""
import json
import shutil
import time
from pathlib import Path

KEEP_BACKUPS = 20


def _paths(list_path: Path):
    history = list_path.parent / ".history"
    return history, history / "pending.json"


def _load(pending_file: Path):
    if not pending_file.exists():
        return []
    try:
        return json.loads(pending_file.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return []


def _save(pending_file: Path, entries):
    pending_file.parent.mkdir(parents=True, exist_ok=True)
    pending_file.write_text(json.dumps(entries, ensure_ascii=False, indent=2), encoding="utf-8")


def snapshot(list_path: Path, label: str):
    """Call before changing the list. Returns the new pending entry."""
    history, pending_file = _paths(list_path)
    history.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S") + f"-{time.time_ns() % 1000000:06d}"
    backup = history / f"{stamp}.txt"
    if list_path.exists():
        shutil.copy2(list_path, backup)
    else:
        backup.write_text("", encoding="utf-8")
    entries = _load(pending_file)
    entry = {"id": stamp, "time": time.strftime("%H:%M:%S"), "label": label, "backup": str(backup)}
    entries.append(entry)
    _save(pending_file, entries)
    _prune(history, entries)
    return entry


def pending(list_path: Path):
    _, pending_file = _paths(list_path)
    return [{"id": e["id"], "time": e["time"], "label": e["label"]} for e in _load(pending_file)]


def confirm(list_path: Path):
    _, pending_file = _paths(list_path)
    count = len(_load(pending_file))
    _save(pending_file, [])
    return count


def revert(list_path: Path):
    """Restore the list as it was before the first pending change. Returns how many changes were undone."""
    _, pending_file = _paths(list_path)
    entries = _load(pending_file)
    if not entries:
        return 0
    first_backup = Path(entries[0]["backup"])
    if first_backup.exists():
        shutil.copy2(first_backup, list_path)
    _save(pending_file, [])
    return len(entries)


def _prune(history: Path, entries):
    """Keep the newest backups; backups of pending entries are never removed."""
    keep = {Path(e["backup"]).name for e in entries}
    files = sorted(history.glob("*.txt"), key=lambda p: p.name)
    for old in files[:-KEEP_BACKUPS]:
        if old.name not in keep:
            old.unlink(missing_ok=True)
