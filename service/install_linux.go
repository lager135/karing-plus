//go:build linux

package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// installedExe is where install copies the service binary. The app bundle may live in a
// user-writable directory; a root service must not run a file the user can replace.
const (
	installDir   = "/usr/local/lib/karingplus"
	installedExe = installDir + "/karingService"
	unitPath     = "/etc/systemd/system/" + unitName
)

const unitTemplate = `[Unit]
Description=%s
Documentation=%s
After=network.target

[Service]
Type=simple
ExecStart=%s service
Restart=on-failure
RestartSec=5
# The core creates the TUN interface and routes, so it runs as root.
User=root
UMask=0077

[Install]
WantedBy=multi-user.target
`

func requireRoot() error {
	if os.Geteuid() != 0 {
		return errors.New("must run as root (use pkexec or sudo)")
	}
	return nil
}

func requireSystemd() error {
	if fi, err := os.Stat("/run/systemd/system"); err != nil || !fi.IsDir() {
		return errors.New("systemd is not running on this system")
	}
	if _, err := exec.LookPath("systemctl"); err != nil {
		return errors.New("systemctl not found")
	}
	return nil
}

func systemctl(args ...string) error {
	out, err := exec.Command("systemctl", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("systemctl %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

// copyExe copies the running binary to installedExe (root:root 0755) through a temp file and a
// rename, so a running old copy is replaced safely.
func copyExe() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, _ = filepath.EvalSymlinks(exe)
	if exe == installedExe {
		return nil
	}
	if err := os.MkdirAll(installDir, 0o755); err != nil {
		return err
	}
	src, err := os.Open(exe)
	if err != nil {
		return err
	}
	defer src.Close()
	tmp, err := os.CreateTemp(installDir, ".karingService-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := io.Copy(tmp, src); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o755); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), installedExe)
}

// install writes the secret, copies the binary, writes the systemd unit (enabled at boot) and
// (re)starts it. It needs root. Running it again updates the binary and the secret.
func install(secret string) error {
	if !reSecret.MatchString(secret) {
		return errors.New("secret must be 32..128 hex characters")
	}
	if err := requireRoot(); err != nil {
		return err
	}
	if err := requireSystemd(); err != nil {
		return err
	}
	if err := os.MkdirAll(dataDir(), 0o700); err != nil {
		return err
	}
	// Only root may read or change the service data (MkdirAll keeps an existing mode).
	if err := os.Chmod(dataDir(), 0o700); err != nil {
		return err
	}
	_ = os.Chown(dataDir(), 0, 0)
	if err := os.WriteFile(secretPath(), []byte(secret), 0o600); err != nil {
		return err
	}
	_ = os.Chmod(secretPath(), 0o600)
	if err := copyExe(); err != nil {
		return fmt.Errorf("copy service binary: %w", err)
	}
	unit := fmt.Sprintf(unitTemplate, serviceDisplay, serviceDesc, installedExe)
	if err := os.WriteFile(unitPath, []byte(unit), 0o644); err != nil {
		return err
	}
	if err := systemctl("daemon-reload"); err != nil {
		return err
	}
	if err := systemctl("enable", unitName); err != nil {
		return err
	}
	// restart also starts a stopped unit, and makes a running one read the new secret and binary.
	return systemctl("restart", unitName)
}

// uninstall stops and removes the unit and the installed binary. The data dir is kept, as on Windows.
func uninstall() error {
	if err := requireRoot(); err != nil {
		return err
	}
	if _, err := os.Stat(unitPath); err == nil {
		if requireSystemd() == nil {
			_ = systemctl("disable", "--now", unitName)
		}
		if err := os.Remove(unitPath); err != nil {
			return err
		}
		if requireSystemd() == nil {
			_ = systemctl("daemon-reload")
		}
	}
	if err := os.Remove(installedExe); err != nil && !os.IsNotExist(err) {
		return err
	}
	_ = os.Remove(installDir)
	return nil
}
