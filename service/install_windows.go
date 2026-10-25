//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

// install writes the secret, creates the service (auto start) and starts it. It needs admin rights.
// Running it again updates the binary path and the secret.
func install(secret string) error {
	if !reSecret.MatchString(secret) {
		return errors.New("secret must be 32..128 hex characters")
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, _ = filepath.Abs(exe)

	if err := os.MkdirAll(dataDir(), 0o700); err != nil {
		return err
	}
	// Only SYSTEM and Administrators may read or change the service data.
	_ = exec.Command("icacls", dataDir(), "/inheritance:r",
		"/grant:r", "*S-1-5-18:(OI)(CI)F", "/grant:r", "*S-1-5-32-544:(OI)(CI)F").Run()
	if err := os.WriteFile(secretPath(), []byte(secret), 0o600); err != nil {
		return err
	}

	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()

	s, err := m.OpenService(serviceName)
	if err == nil {
		// Already installed: point it at this binary, then restart so it reads the new secret.
		cfg, cerr := s.Config()
		if cerr == nil {
			cfg.BinaryPathName = fmt.Sprintf(`"%s" service`, exe)
			cfg.StartType = mgr.StartAutomatic
			_ = s.UpdateConfig(cfg)
		}
		stopAndWait(s)
		defer s.Close()
		return s.Start()
	}
	s, err = m.CreateService(serviceName, exe, mgr.Config{
		DisplayName: serviceDisplay,
		Description: serviceDesc,
		StartType:   mgr.StartAutomatic,
	}, "service")
	if err != nil {
		return err
	}
	defer s.Close()
	_ = s.SetRecoveryActions([]mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 10 * time.Second},
	}, 600)
	return s.Start()
}

func uninstall() error {
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	s, err := m.OpenService(serviceName)
	if err != nil {
		return nil // not installed
	}
	defer s.Close()
	stopAndWait(s)
	return s.Delete()
}

func stopAndWait(s *mgr.Service) {
	st, err := s.Control(svc.Stop)
	if err != nil {
		return
	}
	deadline := time.Now().Add(15 * time.Second)
	for st.State != svc.Stopped && time.Now().Before(deadline) {
		time.Sleep(300 * time.Millisecond)
		if st, err = s.Query(); err != nil {
			return
		}
	}
}
