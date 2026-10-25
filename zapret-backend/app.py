"""
Zapret Web UI - FastAPI backend.
"""
import asyncio
import os
import sys
import threading
from pathlib import Path

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.responses import HTMLResponse, Response
from fastapi.staticfiles import StaticFiles

# ZAPRET_ROOT lets the packaged backend (frozen exe) find zapret/ and static/ next to the app data,
# not inside its own bundle.
ROOT = Path(os.environ["ZAPRET_ROOT"]) if os.environ.get("ZAPRET_ROOT") else Path(__file__).parent
sys.path.insert(0, str(ROOT))

from core.platforms import get_platform
from core.blockcheck import run_blockcheck, kill_all_winws
from core.aibypass import apply_ai_bypass, AI_DOMAINS
from core.userlist import read_domains, add_domains, remove_domains
from core.presets import all_presets
from core import discovery, journal

ZAPRET_DIR = ROOT / "zapret"
STATIC_DIR = ROOT / "static"

app = FastAPI(title="Zapret Web UI")
platform = get_platform()

# When the backend runs as a service (Karing+), ZAPRET_TOKEN is set and every API call and websocket
# must carry it, so other programs on the PC cannot drive a process that runs with SYSTEM rights.
API_TOKEN = os.environ.get("ZAPRET_TOKEN", "")


def _token_ok(value: str) -> bool:
    import hmac
    return bool(API_TOKEN) and hmac.compare_digest(value or "", API_TOKEN)


@app.middleware("http")
async def require_token(request, call_next):
    if API_TOKEN:
        if request.headers.get("origin"):
            return Response(status_code=403)
        if not _token_ok(request.headers.get("x-zapret-token", "")):
            return Response(status_code=401)
    return await call_next(request)

if STATIC_DIR.exists():
    app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

blockcheck_state = {"running": False, "cancel": False}

@app.get("/", response_class=HTMLResponse)
async def root():
    idx = STATIC_DIR / "index.html"
    if idx.exists():
        return HTMLResponse(
            content=idx.read_text(encoding="utf-8"),
            headers={"Cache-Control": "no-cache, no-store, must-revalidate"},
        )
    return HTMLResponse(content="<h1>index.html missing</h1>")

@app.get("/test", response_class=HTMLResponse)
async def test_page():
    test_file = STATIC_DIR / "test.html"
    if test_file.exists():
        return HTMLResponse(content=test_file.read_text(encoding="utf-8"))
    return HTMLResponse(content="<h1>test.html missing</h1>")

@app.get("/favicon.ico")
async def favicon():
    svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#00d4ff"/><text x="32" y="44" font-family="sans-serif" font-size="36" font-weight="800" text-anchor="middle" fill="white">Z</text></svg>'
    return Response(content=svg, media_type="image/svg+xml")

@app.get("/api/status")
async def api_status():
    return {"running": platform.is_running(), "platform": platform.name(), "zapret_dir": str(ZAPRET_DIR), "strategies": platform.list_strategies(ZAPRET_DIR)}

@app.post("/api/start")
async def api_start(body: dict):
    strategy = body.get("strategy", "")
    if not strategy:
        raise HTTPException(400, "strategy required")
    ok, msg = platform.start(strategy, ZAPRET_DIR)
    return {"ok": ok, "message": msg, "running": platform.is_running()}

@app.post("/api/stop")
async def api_stop():
    platform.stop()
    kill_all_winws()
    return {"ok": True, "running": False}

@app.post("/api/killall")
async def api_killall():
    return {"killed": kill_all_winws()}

USER_LIST = ZAPRET_DIR / "lists" / "list-general-user.txt"

@app.get("/api/hostlist")
async def api_hostlist():
    return {"domains": read_domains(USER_LIST)}

@app.post("/api/hostlist/add")
async def api_hostlist_add(body: dict):
    domain = body.get("domain", "").strip().lower()
    if not domain:
        raise HTTPException(400, "domain required")
    journal.snapshot(USER_LIST, f"Добавлен сайт: {domain}")
    add_domains(USER_LIST, [domain])
    return {"ok": True}

@app.post("/api/hostlist/remove")
async def api_hostlist_remove(body: dict):
    domain = body.get("domain", "").strip()
    if not domain:
        return {"ok": False}
    journal.snapshot(USER_LIST, f"Удалён сайт: {domain}")
    remove_domains(USER_LIST, [domain])
    return {"ok": True}

@app.post("/api/services/search")
async def api_services_search(body: dict):
    query = body.get("query", "").strip()
    if not query:
        raise HTTPException(400, "query required")
    # Network lookups run in a thread so status requests keep answering.
    return await asyncio.to_thread(discovery.search, query)

@app.post("/api/services/add")
async def api_services_add(body: dict):
    query = body.get("query", "").strip()
    domains = [d.strip().lower() for d in body.get("domains", []) if isinstance(d, str) and d.strip()]
    if not domains:
        raise HTTPException(400, "domains required")
    journal.snapshot(USER_LIST, f"Добавлен сервис: {query or 'без названия'} ({len(domains)} адр.)")
    added = add_domains(USER_LIST, domains)
    return {"ok": True, "added": added}

@app.get("/api/changes")
async def api_changes():
    return {"pending": journal.pending(USER_LIST)}

@app.post("/api/changes/confirm")
async def api_changes_confirm():
    return {"ok": True, "confirmed": journal.confirm(USER_LIST)}

@app.post("/api/changes/revert")
async def api_changes_revert():
    return {"ok": True, "reverted": journal.revert(USER_LIST)}

@app.get("/api/presets")
async def api_presets():
    enabled_now = set(read_domains(USER_LIST))
    result = {}
    for key, info in all_presets().items():
        on = all(d in enabled_now for d in info["domains"])
        result[key] = {"title": info["title"], "kind": info["kind"], "count": len(info["domains"]), "enabled": on}
    return result

@app.post("/api/popular/update")
async def api_popular_update():
    from core.popular import update_user_list
    journal.snapshot(USER_LIST, "Популярные сервисы (автопоиск)")
    # Network work runs in a thread so the event loop keeps serving status requests.
    return await asyncio.to_thread(update_user_list, ZAPRET_DIR)

@app.post("/api/presets/toggle")
async def api_presets_toggle(body: dict):
    key = body.get("name", "")
    presets = all_presets()
    if key not in presets:
        raise HTTPException(404, "unknown preset")
    domains = presets[key]["domains"]
    action = "Включено" if body.get("enabled") else "Выключено"
    journal.snapshot(USER_LIST, f"{action}: {presets[key]['title']}")
    if body.get("enabled"):
        add_domains(USER_LIST, domains)
    else:
        remove_domains(USER_LIST, domains)
    return {"ok": True, "name": key, "enabled": bool(body.get("enabled"))}

@app.get("/api/aibypass/services")
async def api_ai_services():
    return {name: len(info["domains"]) for name, info in AI_DOMAINS.items()}

@app.post("/api/aibypass/apply")
async def api_ai_apply():
    return apply_ai_bypass(ZAPRET_DIR)

@app.get("/api/updates/check")
async def api_updates():
    from core.updater import check_for_updates, get_latest_release, BUNDLE_REPO, repos_configured
    if not repos_configured():
        return {"configured": False, "message": "Адрес обновлений не настроен: укажите bundle_repo и gui_repo в config.json"}
    return {"configured": True, "gui": check_for_updates(), "bundle": get_latest_release(BUNDLE_REPO)}

@app.websocket("/ws/blockcheck")
async def ws_blockcheck(ws: WebSocket):
    if API_TOKEN and not _token_ok(ws.query_params.get("token", "")):
        await ws.close(code=1008)
        return
    await ws.accept()
    if blockcheck_state["running"]:
        await ws.send_json({"type": "error", "message": "already running"})
        await ws.close()
        return
    blockcheck_state.update({"running": True, "cancel": False})
    loop = asyncio.get_event_loop()
    queue = asyncio.Queue()
    def on_progress(index, total, strategy, result):
        if blockcheck_state["cancel"]:
            return
        message = f"[{index}/{total}] {strategy}..." if result is None else f"[{index}/{total}] {strategy}: {'OK' if result.get('ok') else 'FAIL'}"
        asyncio.run_coroutine_threadsafe(queue.put(("progress", message, result)), loop)
    def worker():
        try:
            result = run_blockcheck(ZAPRET_DIR, on_progress=on_progress, cancel_check=lambda: blockcheck_state["cancel"])
            asyncio.run_coroutine_threadsafe(queue.put(("done", result, None)), loop)
        except Exception as exc:
            asyncio.run_coroutine_threadsafe(queue.put(("error", str(exc), None)), loop)
        finally:
            blockcheck_state["running"] = False
    threading.Thread(target=worker, daemon=True).start()
    try:
        while True:
            kind, payload, result = await queue.get()
            if kind == "progress":
                await ws.send_json({"type": "progress", "message": payload, "result": result})
            elif kind == "done":
                await ws.send_json({"type": "done", "result": payload})
                break
            else:
                await ws.send_json({"type": "error", "message": payload})
                break
    except WebSocketDisconnect:
        blockcheck_state["cancel"] = True
    finally:
        try:
            await ws.close()
        except Exception:
            pass

@app.websocket("/ws/logs")
async def ws_logs(ws: WebSocket):
    if API_TOKEN and not _token_ok(ws.query_params.get("token", "")):
        await ws.close(code=1008)
        return
    await ws.accept()
    try:
        while True:
            await ws.send_json({"running": platform.is_running()})
            await asyncio.sleep(2)
    except WebSocketDisconnect:
        pass

if __name__ == "__main__":
    port = int(os.environ.get("ZAPRET_PORT", "8091"))
    print(f"Starting Zapret Web UI on http://127.0.0.1:{port}")
    print("Open this URL manually in your browser (NOT https)")
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="info")