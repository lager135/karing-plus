//go:build !windows

package main

import (
	"os/exec"
	"syscall"
)

// On Linux the core gets SIGKILL when the service dies, so no orphan keeps the TUN interface.
func setChildAttrs(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
}

func bindChild(cmd *exec.Cmd) {}
