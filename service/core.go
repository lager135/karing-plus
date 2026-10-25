package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	sjson "github.com/sagernet/sing/common/json"
)

// The sing-box core runs in a child process of the service ("karingService core"). A core that does
// not close in time can then be killed at once: the OS frees its TUN adapter with the process, so a
// reconnect does not wait, and all of its memory goes back to the system.

const (
	coreReadyTimeout = 90 * time.Second
	coreStopGrace    = 1500 * time.Millisecond
)

// core supervises at most one core process.
type core struct {
	mu      sync.Mutex
	proc    *coreProc
	lastErr string
}

type coreProc struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	exited chan struct{}
	ready  bool
}

// sanitize keeps the service from writing files where the request says. The core runs as SYSTEM,
// so log and cache paths are forced into the service data dir.
func sanitize(raw []byte) ([]byte, error) {
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("config is not valid JSON: %w", err)
	}
	normalizeKaring(m)
	if l, ok := m["log"].(map[string]any); ok {
		if _, set := l["output"]; set {
			l["output"] = filepath.Join(dataDir(), "core.log")
		}
	}
	if exp, ok := m["experimental"].(map[string]any); ok {
		if cf, ok := exp["cache_file"].(map[string]any); ok {
			cf["path"] = filepath.Join(dataDir(), "cache.db")
		}
		if ca, ok := exp["clash_api"].(map[string]any); ok {
			// The external UI would be served from a path the caller chooses; drop it.
			delete(ca, "external_ui")
			delete(ca, "external_ui_download_url")
		}
	}
	return json.Marshal(m)
}

// decodable drops the fields only Karing's own core knows, one at a time, until the config decodes.
func decodable(content []byte) ([]byte, error) {
	ctx, cancel := context.WithCancel(include.Context(context.Background()))
	defer cancel()
	_, err := sjson.UnmarshalExtendedContext[option.Options](ctx, content)
	for i := 0; err != nil && i < 200; i++ {
		next, what, ok := dropUnknownField(content, err)
		if !ok {
			break
		}
		log.Printf("config: dropped unsupported field %s", what)
		content = next
		_, err = sjson.UnmarshalExtendedContext[option.Options](ctx, content)
	}
	return content, err
}

func (c *core) start(raw []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.proc != nil {
		// The user reconnects while the old core still runs or is closing: no waiting, kill it.
		log.Printf("core: previous core killed by user (restart)")
		c.killLocked()
	}
	content, err := sanitize(raw)
	if err != nil {
		c.lastErr = err.Error()
		return err
	}
	if err := os.MkdirAll(dataDir(), 0o700); err != nil {
		return err
	}
	content, err = decodable(content)
	if err != nil {
		c.lastErr = "decode config: " + err.Error()
		return errors.New(c.lastErr)
	}
	// Tell the zapret module which addresses are VPN servers, so winws leaves them alone.
	noteVPNServers(serverAddresses(content))

	p, err := spawnCore(content)
	if err != nil {
		c.lastErr = "start core: " + err.Error()
		return errors.New(c.lastErr)
	}
	c.proc, c.lastErr = p, ""
	return nil
}

// spawnCore starts a core process, hands it the config and waits until it reports READY or an error.
func spawnCore(content []byte) (*coreProc, error) {
	exe, err := os.Executable()
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(exe, "core")
	cmd.Dir = dataDir()
	setChildAttrs(cmd)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = log.Writer()
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	bindChild(cmd)
	p := &coreProc{cmd: cmd, stdin: stdin, exited: make(chan struct{})}

	// Config: one line with its length, then the bytes.
	if _, err := fmt.Fprintf(stdin, "%d\n", len(content)); err == nil {
		_, err = stdin.Write(content)
	}

	answer := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(stdout).ReadString('\n')
		answer <- strings.TrimSpace(line)
		_, _ = io.Copy(io.Discard, stdout)
	}()
	go func() {
		_ = cmd.Wait()
		close(p.exited)
	}()

	select {
	case line := <-answer:
		if line == "READY" {
			p.ready = true
			return p, nil
		}
		p.kill()
		msg := strings.TrimPrefix(line, "ERROR ")
		if msg == "" {
			msg = "core exited"
		}
		return nil, errors.New(msg)
	case <-p.exited:
		return nil, errors.New("core exited during start")
	case <-time.After(coreReadyTimeout):
		p.kill()
		return nil, errors.New("core did not start in time")
	}
}

func (p *coreProc) alive() bool {
	select {
	case <-p.exited:
		return false
	default:
		return true
	}
}

// kill ends the process at once and waits until it is gone.
func (p *coreProc) kill() {
	if p.cmd.Process != nil {
		_ = p.cmd.Process.Kill()
	}
	select {
	case <-p.exited:
	case <-time.After(5 * time.Second):
	}
}

func (c *core) killLocked() {
	if c.proc != nil {
		c.proc.kill()
		c.proc = nil
	}
}

// stop asks the core to close and gives it coreStopGrace; after that the process is killed.
func (c *core) stop() {
	c.mu.Lock()
	defer c.mu.Unlock()
	p := c.proc
	if p == nil {
		return
	}
	c.proc = nil
	_, _ = io.WriteString(p.stdin, "stop\n")
	_ = p.stdin.Close()
	select {
	case <-p.exited:
	case <-time.After(coreStopGrace):
		log.Printf("core: did not close in %s, killed (disconnect)", coreStopGrace)
		p.kill()
	}
}

func (c *core) state() (string, string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.proc != nil {
		if c.proc.alive() {
			return "connected", ""
		}
		c.proc = nil
		c.lastErr = "core exited unexpectedly"
	}
	return "disconnected", c.lastErr
}

// runCoreChild is the "core" command: read the config from stdin, run sing-box, print READY or
// ERROR <text>, and close on "stop" or when stdin closes (the service went away).
func runCoreChild() {
	in := bufio.NewReader(os.Stdin)
	line, err := in.ReadString('\n')
	if err != nil {
		fmt.Println("ERROR no config")
		os.Exit(1)
	}
	n, err := strconv.Atoi(strings.TrimSpace(line))
	if err != nil || n <= 0 || n > maxConfigBytes {
		fmt.Println("ERROR bad config length")
		os.Exit(1)
	}
	content := make([]byte, n)
	if _, err := io.ReadFull(in, content); err != nil {
		fmt.Println("ERROR config truncated")
		os.Exit(1)
	}

	var instance *box.Box
	for attempt := 1; ; attempt++ {
		ctx := include.Context(context.Background())
		options, err := sjson.UnmarshalExtendedContext[option.Options](ctx, content)
		if err != nil {
			fmt.Println("ERROR decode config: " + oneLine(err))
			os.Exit(1)
		}
		instance, err = box.New(box.Options{Context: ctx, Options: options})
		if err != nil {
			fmt.Println("ERROR create core: " + oneLine(err))
			os.Exit(1)
		}
		err = instance.Start()
		if err == nil {
			break
		}
		_ = instance.Close()
		if attempt >= 3 || !strings.Contains(err.Error(), "tun") {
			fmt.Println("ERROR start core: " + oneLine(err))
			os.Exit(1)
		}
		log.Printf("core: start attempt %d failed (%v), retrying", attempt, err)
		time.Sleep(time.Second)
	}
	fmt.Println("READY")

	// Wait for "stop" or EOF.
	for {
		l, err := in.ReadString('\n')
		if err != nil || strings.TrimSpace(l) == "stop" {
			break
		}
	}
	_ = instance.Close()
	os.Exit(0)
}

func oneLine(err error) string {
	return strings.ReplaceAll(strings.ReplaceAll(err.Error(), "\r", " "), "\n", " ")
}

// checkConfig runs the same decode path as start and creates the core, but does not start it.
func checkConfig(path string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	content, err := sanitize(raw)
	if err != nil {
		return err
	}
	log.SetOutput(os.Stdout)
	content, err = decodable(content)
	if err != nil {
		return fmt.Errorf("decode config: %w", err)
	}
	ctx, cancel := context.WithCancel(include.Context(context.Background()))
	defer cancel()
	options, err := sjson.UnmarshalExtendedContext[option.Options](ctx, content)
	if err != nil {
		return fmt.Errorf("decode config: %w", err)
	}
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		return fmt.Errorf("create core: %w", err)
	}
	return instance.Close()
}
