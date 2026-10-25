//go:build windows

package main

import (
	"context"
	"log"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows/svc"
)

func runForeground() error {
	return serve(context.Background())
}

type handler struct{}

func (handler) Execute(_ []string, req <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- serve(ctx) }()
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case err := <-done:
			cancel()
			if err != nil {
				log.Printf("service stopped: %v", err)
				return false, 1
			}
			return false, 0
		case r := <-req:
			switch r.Cmd {
			case svc.Interrogate:
				status <- r.CurrentStatus
			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				cancel()
				<-done
				return false, 0
			}
		}
	}
}

func runService() {
	if err := svc.Run(serviceName, handler{}); err != nil {
		log.Fatal(err)
	}
}

const (
	serviceName = "KaringPlusService"
	usageText   = "usage: karingService.exe install -secret <hex> | uninstall | run | version"
)

// dataDir is where the service keeps its secret, logs and cache. Only SYSTEM and Administrators can write it.
func dataDir() string {
	base := os.Getenv("ProgramData")
	if base == "" {
		base = `C:\ProgramData`
	}
	return filepath.Join(base, "KaringPlus")
}

// startedByServiceManager reports whether the Windows service control manager started this process.
func startedByServiceManager() bool {
	inService, err := svc.IsWindowsService()
	return err == nil && inService
}
