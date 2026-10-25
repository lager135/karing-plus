//go:build linux

package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"
)

const (
	// unitName is the systemd unit created by install.
	unitName  = "karingplus.service"
	usageText = "usage: karingService install -secret-file <path> | uninstall | run | check <config.json> | version"
)

// dataDir is where the service keeps its secret, logs and cache. Only root can read it (0700).
func dataDir() string { return "/var/lib/karingplus" }

// startedByServiceManager: systemd starts the unit with the explicit "service" argument.
func startedByServiceManager() bool { return false }

// serveUntilSignal runs the control server until SIGINT or SIGTERM (systemd stop).
func serveUntilSignal() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return serve(ctx)
}

func runForeground() error {
	if os.Geteuid() != 0 {
		// Still useful for /version and check-style debugging; the TUN inbound will fail without root.
		println("warning: not running as root; a TUN inbound will fail to start")
	}
	return serveUntilSignal()
}

func runService() {
	if err := serveUntilSignal(); err != nil {
		// systemd restarts the unit on failure (Restart=on-failure).
		println("service stopped:", err.Error())
		os.Exit(1)
	}
}
