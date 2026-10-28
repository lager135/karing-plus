//go:build !windows && !linux

package main

import "errors"

// zapretSupported: the zapret backend exists for Windows and Linux only. On other systems the
// zapret endpoints answer 501 "not supported" and this type does nothing.
const zapretSupported = false

var errZapretUnsupported = errors.New("zapret is not supported on this system")

type zapret struct{}

func (z *zapret) start() error                 { return errZapretUnsupported }
func (z *zapret) stop()                        {}
func (z *zapret) running() bool                { return false }
func (z *zapret) info() (bool, string, string) { return false, "", "" }

// noteVPNServers is a no-op where zapret is not supported.
func noteVPNServers(ips []string) {}
