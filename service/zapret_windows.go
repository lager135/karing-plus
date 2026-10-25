//go:build windows

package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// zapret runs the bundled zapret backend (FastAPI + winws) as SYSTEM, because winws needs admin rights.
// The binary path is fixed next to the service (zapret\backend\zapret-backend.exe); requests cannot choose it.
type zapret struct {
	mu    sync.Mutex
	cmd   *exec.Cmd
	token string
}

// zapretSupported: the zapret backend (winws) exists for Windows only.
const zapretSupported = true

// zapretPort is separate from the standalone Zapret app (8091), so both can be installed.
const zapretPort = "8092"

func newToken() string {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func zapretDir() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return filepath.Join(filepath.Dir(exe), "zapret")
}

func (z *zapret) start() error {
	z.mu.Lock()
	defer z.mu.Unlock()
	if z.cmd != nil && z.cmd.ProcessState == nil {
		return nil // already running
	}
	dir := zapretDir()
	backend := filepath.Join(dir, "backend", "zapret-backend.exe")
	web := filepath.Join(dir, "zapret-web")
	if _, err := os.Stat(backend); err != nil {
		return errors.New("zapret backend not found next to the service")
	}
	logf, _ := os.OpenFile(filepath.Join(dataDir(), "zapret.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	cmd := exec.Command(backend)
	cmd.Dir = filepath.Dir(backend)
	token := newToken()
	cmd.Env = append(os.Environ(), "ZAPRET_ROOT="+web, "ZAPRET_PORT="+zapretPort, "ZAPRET_TOKEN="+token, "ZAPRET_KARING=1")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if logf != nil {
		cmd.Stdout, cmd.Stderr = logf, logf
	}
	if err := cmd.Start(); err != nil {
		if logf != nil {
			logf.Close()
		}
		return err
	}
	z.cmd, z.token = cmd, token
	go func() {
		_ = cmd.Wait()
		if logf != nil {
			logf.Close()
		}
	}()
	return nil
}

// stop ends the backend and every winws it started.
// stop ends our backend and only the winws processes started from our zapret folder.
// Another zapret copy on the PC (for example the standalone Zapret app) keeps running.
func (z *zapret) stop() {
	z.mu.Lock()
	defer z.mu.Unlock()
	if z.cmd != nil && z.cmd.Process != nil && z.cmd.ProcessState == nil {
		// Let the backend stop its own winws first, then end its process tree.
		if z.token != "" {
			req, _ := http.NewRequest("POST", "http://127.0.0.1:"+zapretPort+"/api/stop", nil)
			req.Header.Set("X-Zapret-Token", z.token)
			client := &http.Client{Timeout: 5 * time.Second}
			if resp, err := client.Do(req); err == nil {
				resp.Body.Close()
			}
		}
		_ = exec.Command("taskkill", "/F", "/T", "/PID", strconv.Itoa(z.cmd.Process.Pid)).Run()
		_ = z.cmd.Process.Kill()
	}
	z.cmd, z.token = nil, ""
	killOwnWinws()
}

// killOwnWinws stops winws.exe whose executable lies under our zapret folder.
func killOwnWinws() {
	dir := strings.ToLower(zapretDir())
	if dir == "" {
		return
	}
	out, err := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command",
		"Get-CimInstance Win32_Process -Filter \"Name='winws.exe'\" | ForEach-Object { \"$($_.ProcessId)|$($_.ExecutablePath)\" }").Output()
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(out), "\n") {
		pid, path, ok := strings.Cut(strings.TrimSpace(line), "|")
		if !ok || !strings.HasPrefix(strings.ToLower(path), dir+string(os.PathSeparator)) {
			continue
		}
		if _, err := strconv.Atoi(pid); err == nil {
			_ = exec.Command("taskkill", "/F", "/PID", pid).Run()
		}
	}
}

func (z *zapret) running() bool {
	z.mu.Lock()
	defer z.mu.Unlock()
	return z.cmd != nil && z.cmd.ProcessState == nil
}

// info returns whether the backend runs, and its port and token for the app.
func (z *zapret) info() (bool, string, string) {
	z.mu.Lock()
	defer z.mu.Unlock()
	if z.cmd != nil && z.cmd.ProcessState == nil {
		return true, zapretPort, z.token
	}
	return false, "", ""
}

// noteVPNServers writes the VPN server IPs to the zapret exclude list (lists/ipset-exclude-karing.txt).
// The strategy copy that Karing+ runs passes it to winws as --ipset-exclude.
func noteVPNServers(ips []string) {
	dir := zapretDir()
	if dir == "" {
		return
	}
	lists := filepath.Join(dir, "zapret-web", "zapret", "lists")
	if _, err := os.Stat(lists); err != nil {
		return
	}
	var b strings.Builder
	b.WriteString("203.0.113.255/32\n") // TEST-NET placeholder, keeps the list non-empty
	for _, ip := range ips {
		if strings.Contains(ip, ":") {
			b.WriteString(ip + "/128\n")
		} else {
			b.WriteString(ip + "/32\n")
		}
	}
	_ = os.WriteFile(filepath.Join(lists, "ipset-exclude-karing.txt"), []byte(b.String()), 0o644)
}
