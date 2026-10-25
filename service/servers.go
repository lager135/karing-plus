package main

import (
	"context"
	"encoding/json"
	"net"
	"net/netip"
	"sort"
	"sync"
	"time"
)

// serverAddresses returns the IPs of every outbound server in a sing-box config. Host names are
// resolved; a name that does not resolve in time is skipped.
func serverAddresses(content []byte) []string {
	var cfg struct {
		Outbounds []struct {
			Server string `json:"server"`
		} `json:"outbounds"`
	}
	if json.Unmarshal(content, &cfg) != nil {
		return nil
	}
	seen := map[string]bool{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	add := func(ip netip.Addr) {
		mu.Lock()
		seen[ip.Unmap().String()] = true
		mu.Unlock()
	}
	names := map[string]bool{}
	for _, o := range cfg.Outbounds {
		if o.Server == "" {
			continue
		}
		if ip, err := netip.ParseAddr(o.Server); err == nil {
			add(ip)
			continue
		}
		names[o.Server] = true
	}
	for name := range names {
		wg.Add(1)
		go func(name string) {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
			defer cancel()
			ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", name)
			if err != nil {
				return
			}
			for _, ip := range ips {
				add(ip)
			}
		}(name)
	}
	wg.Wait()
	out := make([]string, 0, len(seen))
	for s := range seen {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}
