//go:build linux

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

// zapret runs the bundled zapret backend (FastAPI) as root, because nfqws and nftables need it.
// The backend runs strategies with nfqws (see zapret-backend core/platforms/linux.py).
// The binary path is fixed next to the service (zapret/backend/zapret-backend); requests cannot choose it.
type zapret struct {
	mu    sync.Mutex
	cmd   *exec.Cmd
	token string
}

const zapretSupported = true

// zapretPort matches the Windows build, so the app talks to the backend the same way.
const zapretPort = "8092"

// nftTable is the nftables table the backend uses for the NFQUEUE rules.
const nftTable = "karingplus_zapret"

// iptChain is the iptables chain the backend uses where nft is missing.
const iptChain = "KARINGPLUS_ZAPRET"

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
	backend := filepath.Join(dir, "backend", "zapret-backend")
	web := filepath.Join(dir, "zapret-web")
	if _, err := os.Stat(backend); err != nil {
		return errors.New("zapret backend not found next to the service")
	}
	logf, _ := os.OpenFile(filepath.Join(dataDir(), "zapret.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	cmd := exec.Command(backend)
	cmd.Dir = filepath.Dir(backend)
	token := newToken()
	cmd.Env = append(os.Environ(), "ZAPRET_ROOT="+web, "ZAPRET_PORT="+zapretPort, "ZAPRET_TOKEN="+token, "ZAPRET_KARING=1")
	// Own process group: stop() ends the backend together with its nfqws.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
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

// stop ends our backend, the nfqws processes started from our zapret folder and the nftables rules.
// Another zapret on the system (its own nfqws binary and table) keeps running.
func (z *zapret) stop() {
	z.mu.Lock()
	defer z.mu.Unlock()
	if z.cmd != nil && z.cmd.Process != nil && z.cmd.ProcessState == nil {
		// Let the backend stop its own nfqws and remove its rules first.
		if z.token != "" {
			req, _ := http.NewRequest("POST", "http://127.0.0.1:"+zapretPort+"/api/stop", nil)
			req.Header.Set("X-Zapret-Token", z.token)
			client := &http.Client{Timeout: 5 * time.Second}
			if resp, err := client.Do(req); err == nil {
				resp.Body.Close()
			}
		}
		_ = syscall.Kill(-z.cmd.Process.Pid, syscall.SIGTERM)
		time.Sleep(300 * time.Millisecond)
		_ = syscall.Kill(-z.cmd.Process.Pid, syscall.SIGKILL)
	}
	z.cmd, z.token = nil, ""
	killOwnNfqws()
	_ = exec.Command("nft", "delete", "table", "inet", nftTable).Run()
	for _, ipt := range []string{"iptables", "ip6tables"} {
		for exec.Command(ipt, "-t", "mangle", "-D", "POSTROUTING", "-j", iptChain).Run() == nil {
		}
		_ = exec.Command(ipt, "-t", "mangle", "-F", iptChain).Run()
		_ = exec.Command(ipt, "-t", "mangle", "-X", iptChain).Run()
	}
}

// killOwnNfqws stops nfqws whose executable lies under our zapret folder.
func killOwnNfqws() {
	dir := zapretDir()
	if dir == "" {
		return
	}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return
	}
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		exe, err := os.Readlink(filepath.Join("/proc", e.Name(), "exe"))
		if err != nil || filepath.Base(exe) != "nfqws" || !strings.HasPrefix(exe, dir+string(os.PathSeparator)) {
			continue
		}
		_ = syscall.Kill(pid, syscall.SIGKILL)
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
// The backend passes it to nfqws as --ipset-exclude, so zapret leaves the VPN connection alone.
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
