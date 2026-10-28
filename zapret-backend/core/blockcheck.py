"""Native Python blockcheck with guaranteed process cleanup."""
import atexit
import signal
import subprocess
import sys
import time
import threading
from pathlib import Path
from urllib.request import Request, urlopen
import psutil

_CHILD_PROCS = set()
def _register(proc): _CHILD_PROCS.add(proc)
def _unregister(proc): _CHILD_PROCS.discard(proc)
def _kill_proc_tree(pid, timeout=3):
    try: parent=psutil.Process(pid)
    except psutil.NoSuchProcess: return
    children=parent.children(recursive=True)
    for child in children:
        try: child.terminate()
        except psutil.NoSuchProcess: pass
    try: parent.terminate()
    except psutil.NoSuchProcess: pass
    _,alive=psutil.wait_procs(children+[parent],timeout=timeout)
    for process in alive:
        try: process.kill()
        except psutil.NoSuchProcess: pass
def _own_dir():
    """The zapret folder this backend works with; only processes started from it are ours."""
    import os
    from pathlib import Path
    root = os.environ.get("ZAPRET_ROOT")
    base = Path(root) if root else Path(__file__).resolve().parent.parent
    return str((base / "zapret").resolve()).lower()


def _is_ours(process):
    # Another zapret copy (for example the standalone app next to Karing+) may run its own winws;
    # leave those alone.
    try:
        exe = (process.exe() or "").lower()
    except Exception:
        return False
    return exe.startswith(_own_dir())


def kill_all_winws():
    killed=[]
    try:
        for process in psutil.process_iter(["name","pid"]):
            if (process.info.get("name") or "").lower()=="winws.exe" and _is_ours(process):
                try:
                    _kill_proc_tree(process.info["pid"])
                    killed.append(process.info["pid"])
                except Exception: pass
        own=_own_dir()
        for process in psutil.process_iter(["name","cmdline","pid"]):
            try:
                name=(process.info.get("name") or "").lower()
                cmdline=" ".join(process.info.get("cmdline") or []).lower()
                if name=="cmd.exe" and (".bat" in cmdline or "winws" in cmdline) and own in cmdline:
                    _kill_proc_tree(process.info["pid"])
                    killed.append(process.info["pid"])
            except Exception: pass
        # No global "taskkill /IM winws.exe": it would also stop winws of another zapret copy.
    except Exception: pass
    finally:
        try: _CHILD_PROCS.clear()
        except Exception: pass
    return killed
_CLEANUP_LOCK=threading.Lock()
_CLEANUP_DONE=False
def _atexit_cleanup():
    global _CLEANUP_DONE
    with _CLEANUP_LOCK:
        if _CLEANUP_DONE: return
        _CLEANUP_DONE=True
    try: kill_all_winws()
    except Exception: pass
def _signal_handler(signum,frame):
    _atexit_cleanup()
    import os
    os._exit(0)
atexit.register(_atexit_cleanup)
if sys.platform!="win32":
    signal.signal(signal.SIGINT,_signal_handler)
    signal.signal(signal.SIGTERM,_signal_handler)
else:
    try: signal.signal(signal.SIGINT,_signal_handler)
    except Exception: pass
def _test_url(url,timeout=8):
    started=time.time()
    try:
        with urlopen(Request(url,headers={"User-Agent":"Mozilla/5.0"}),timeout=timeout) as response: response.read(1024)
        return True,(time.time()-started)*1000
    except Exception: return False,-1.0
def _test_strategy_linux(strategy,zapret_dir,targets,wait_sec,cancel_check):
    # Linux: the strategy runs through nfqws + nftables (core/platforms/linux.py).
    from core.platforms.linux import LinuxPlatform
    runner=LinuxPlatform()
    try:
        ok,msg=runner.start(strategy,zapret_dir)
        if not ok: return {"strategy":strategy,"ok":False,"error":msg}
        deadline=time.time()+wait_sec
        while time.time()<deadline:
            if cancel_check and cancel_check(): return {"strategy":strategy,"ok":False,"error":"cancelled"}
            time.sleep(0.3)
        details={}
        for target in targets:
            if cancel_check and cancel_check(): return {"strategy":strategy,"ok":False,"error":"cancelled"}
            ok,ms=_test_url(target); details[target]={"ok":ok,"ms":ms}
        successful=[x["ms"] for x in details.values() if x["ok"] and x["ms"]>0]; score=sum(x["ok"] for x in details.values())
        return {"strategy":strategy,"ok":score>0,"score":score,"total":len(targets),"avg_ms":sum(successful)/len(successful) if successful else 0,"details":details}
    finally:
        runner.stop()
def test_strategy(strategy,zapret_dir,targets,wait_sec=4,cancel_check=None):
    if sys.platform!="win32": return _test_strategy_linux(strategy,zapret_dir,targets,wait_sec,cancel_check)
    kill_all_winws(); bat=zapret_dir/f"{strategy}.bat"
    if not bat.exists(): return {"strategy":strategy,"ok":False,"error":"bat not found"}
    proc=None
    try:
        proc=subprocess.Popen(
            ["cmd","/c",str(bat)],
            cwd=str(zapret_dir),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW,
        ); _register(proc); deadline=time.time()+wait_sec
        while time.time()<deadline:
            if cancel_check and cancel_check(): return {"strategy":strategy,"ok":False,"error":"cancelled"}
            time.sleep(0.3)
        details={}
        for target in targets:
            if cancel_check and cancel_check(): return {"strategy":strategy,"ok":False,"error":"cancelled"}
            ok,ms=_test_url(target); details[target]={"ok":ok,"ms":ms}
        successful=[x["ms"] for x in details.values() if x["ok"] and x["ms"]>0]; score=sum(x["ok"] for x in details.values())
        return {"strategy":strategy,"ok":score>0,"score":score,"total":len(targets),"avg_ms":sum(successful)/len(successful) if successful else 0,"details":details}
    except Exception as exc: return {"strategy":strategy,"ok":False,"error":str(exc)}
    finally:
        if proc is not None:
            try:
                if proc.poll() is None: _kill_proc_tree(proc.pid)
            except Exception: pass
            _unregister(proc)
        kill_all_winws()
def run_blockcheck(zapret_dir,on_progress=None,cancel_check=None):
    try:
        strategies=sorted(f.stem for f in zapret_dir.glob("*.bat") if not f.stem.lower().startswith(("service","uninstall","install","update","check"))); targets=["https://www.youtube.com/","https://discord.com/","https://www.instagram.com/"]; results=[]
        for index,strategy in enumerate(strategies,1):
            if cancel_check and cancel_check(): break
            if on_progress: on_progress(index,len(strategies),strategy,None)
            result=test_strategy(strategy,zapret_dir,targets,cancel_check=cancel_check); results.append(result)
            if on_progress: on_progress(index,len(strategies),strategy,result)
        working=sorted((x for x in results if x.get("ok")),key=lambda x:(-x.get("score",0),x.get("avg_ms",999999))); best=working[0]["strategy"] if working else None
        return {"strategies_tested":len(results),"working":[x["strategy"] for x in working],"best":best,"results":results}
    finally: kill_all_winws(); kill_all_winws()
if __name__=="__main__":
    directory=Path(sys.argv[1]) if len(sys.argv)>1 else Path("zapret")
    def callback(i,total,strategy,result): print(f"[{i}/{total}] testing {strategy}..." if result is None else f"[{i}/{total}] {strategy}: {'OK' if result.get('ok') else 'FAIL'} avg={result.get('avg_ms',0):.0f}ms")
    try:
        result=run_blockcheck(directory,callback); print(f"\nBest strategy: {result['best']}"); print(f"Working: {result['working']}")
    finally: print("\nCleanup done. Killing leftovers..."); print(f"Killed PIDs: {kill_all_winws()}")
