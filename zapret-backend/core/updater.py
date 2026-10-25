"""Custom updater for the ICE-FUSION zapret bundle and GUI."""
import json
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

import os

# Repos come from config.json (see config.example.json). The defaults are placeholders until the repos exist.
PLACEHOLDER_BUNDLE_REPO = "ICE-FUSION/zapret-bundle"
PLACEHOLDER_GUI_REPO = "ICE-FUSION/zapret-gui"


def _load_config():
    root = Path(os.environ["ZAPRET_ROOT"]) if os.environ.get("ZAPRET_ROOT") else Path(__file__).resolve().parent.parent
    path = root / "config.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return {}


_CONFIG = _load_config()
BUNDLE_REPO = _CONFIG.get("bundle_repo", PLACEHOLDER_BUNDLE_REPO)
GUI_REPO = _CONFIG.get("gui_repo", PLACEHOLDER_GUI_REPO)


def repos_configured():
    """False while the update repos are still the placeholders, so the UI can say so instead of showing a 404."""
    return BUNDLE_REPO != PLACEHOLDER_BUNDLE_REPO and GUI_REPO != PLACEHOLDER_GUI_REPO
USER_AGENT = "zapret-gui/1.0"

def _api_url(repo, path=""): return f"https://api.github.com/repos/{repo}{path}"
def _get_json(url):
    request = Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"})
    with urlopen(request, timeout=15) as response: return json.loads(response.read().decode("utf-8"))
def get_latest_release(repo):
    try:
        data = _get_json(_api_url(repo, "/releases/latest")); return {"tag": data.get("tag_name", "?"), "name": data.get("name", ""), "url": data.get("zipball_url") or data.get("tarball_url"), "published": data.get("published_at", ""), "assets": [{"name": a["name"], "url": a["browser_download_url"]} for a in data.get("assets", [])]}
    except URLError as exc: return {"error": f"network: {exc}"}
    except Exception as exc: return {"error": str(exc)}
def get_default_branch(repo):
    try: return _get_json(_api_url(repo)).get("default_branch", "main")
    except Exception: return "main"
def download_zip(url, dest):
    try:
        request = Request(url, headers={"User-Agent": USER_AGENT})
        with urlopen(request, timeout=60) as response, open(dest, "wb") as output:
            while chunk := response.read(65536): output.write(chunk)
        return True
    except Exception as exc: print(f"download error: {exc}", file=sys.stderr); return False
def update_bundle(zapret_dir: Path, on_progress=None):
    if on_progress: on_progress("Проверяю релизы...")
    release = get_latest_release(BUNDLE_REPO)
    if "error" in release: return {"ok": False, "error": release["error"]}
    branch = get_default_branch(BUNDLE_REPO); url = release.get("url") or f"https://github.com/{BUNDLE_REPO}/archive/refs/heads/{branch}.zip"
    if on_progress: on_progress(f"Скачиваю {release.get('tag', branch)}...")
    with tempfile.TemporaryDirectory() as temporary:
        temp = Path(temporary); archive = temp / "bundle.zip"
        if not download_zip(url, archive): return {"ok": False, "error": "download failed"}
        extracted = temp / "extracted"; extracted.mkdir()
        with zipfile.ZipFile(archive) as bundle: bundle.extractall(extracted)
        entries = list(extracted.iterdir()); src = entries[0] if len(entries) == 1 and entries[0].is_dir() else extracted
        preserved = {}
        for relative in ("lists/auto-hostlist.txt", "lists/zapret-hosts-user.txt"):
            path = zapret_dir / relative
            if path.exists(): preserved[relative] = path.read_bytes()
        for item in zapret_dir.iterdir(): shutil.rmtree(item) if item.is_dir() else item.unlink()
        for item in src.iterdir(): shutil.copytree(item, zapret_dir / item.name) if item.is_dir() else shutil.copy2(item, zapret_dir / item.name)
        for relative, data in preserved.items():
            path = zapret_dir / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
    tag = release.get("tag", branch)
    if on_progress: on_progress(f"Обновлено до {tag}")
    return {"ok": True, "tag": tag, "preserved": list(preserved)}
def check_for_updates():
    version_file = Path(__file__).parent.parent / "VERSION"; local = version_file.read_text().strip() if version_file.exists() else "0.0.0"; release = get_latest_release(GUI_REPO)
    if "error" in release: return {"ok": False, "error": release["error"], "local": local}
    remote = release.get("tag", "?"); return {"ok": True, "local": local, "remote": remote, "url": release.get("url"), "up_to_date": local == remote.lstrip("v")}
if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "check"
    if command == "check": print(json.dumps(check_for_updates(), indent=2))
    elif command == "update-bundle": print(json.dumps(update_bundle(Path(sys.argv[2]) if len(sys.argv) > 2 else Path("zapret"), print), indent=2))
    else: print(f"usage: {sys.argv[0]} check | update-bundle <zapret_dir>")
