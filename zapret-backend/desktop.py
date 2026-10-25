"""Native desktop wrapper for zapret-web."""
import socket
import sys
import threading
import time
from pathlib import Path
import uvicorn
import webview
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from app import app

def find_free_port(start: int = 8091, end: int = 8199) -> int:
    for port in range(start,end):
        with socket.socket() as sock:
            try: sock.bind(("127.0.0.1",port)); return port
            except OSError: pass
    raise RuntimeError("no free port in range")
def start_server(port): uvicorn.run(app,host="127.0.0.1",port=port,log_level="warning")
def wait_for_server(port,timeout=10.0):
    deadline=time.time()+timeout
    while time.time()<deadline:
        try:
            with socket.create_connection(("127.0.0.1",port),timeout=.5): return True
        except OSError: time.sleep(.2)
    return False
def main():
    port=find_free_port(); threading.Thread(target=start_server,args=(port,),daemon=True).start()
    if not wait_for_server(port): print("ERROR: server did not start",file=sys.stderr); raise SystemExit(1)
    try:
        from tray import run_tray
        threading.Thread(target=run_tray,daemon=True).start()
    except Exception: pass
    webview.create_window("Zapret Web UI",f"http://127.0.0.1:{port}/",width=1280,height=800,min_size=(900,600),confirm_close=False,text_select=True)
    webview.start(debug=False,private_mode=False)
if __name__=="__main__": main()
