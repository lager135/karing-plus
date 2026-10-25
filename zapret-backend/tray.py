"""Optional system tray icon."""
try:
    import pystray
    from PIL import Image, ImageDraw
    HAS_TRAY=True
except ImportError:
    HAS_TRAY=False

def make_icon():
    image=Image.new("RGB",(64,64),"#5865f2"); ImageDraw.Draw(image).text((18,20),"Z",fill="white"); return image

def run_tray(on_quit=None):
    if not HAS_TRAY: return
    def quit_app(icon,item):
        icon.stop()
        if on_quit: on_quit()
    pystray.Icon("zapret-web",make_icon(),"Zapret Web UI",menu=pystray.Menu(pystray.MenuItem("Show",lambda *_:None,default=True),pystray.MenuItem("Kill winws",lambda *_:__import__("subprocess").run(["taskkill","/F","/IM","winws.exe"])),pystray.MenuItem("Exit",quit_app))).run()
