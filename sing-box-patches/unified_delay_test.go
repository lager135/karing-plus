package urltest

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

// slowDialer adds a fixed delay to connection setup, like a proxy handshake.
type slowDialer struct{ delay time.Duration }

func (d slowDialer) DialContext(ctx context.Context, network string, dest M.Socksaddr) (net.Conn, error) {
	time.Sleep(d.delay)
	return N.SystemDialer.DialContext(ctx, network, dest)
}

func (d slowDialer) ListenPacket(ctx context.Context, dest M.Socksaddr) (net.PacketConn, error) {
	return N.SystemDialer.ListenPacket(ctx, dest)
}

func TestUnifiedDelayExcludesHandshake(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()
	ms, err := URLTest(context.Background(), srv.URL+"/generate_204", slowDialer{delay: 200 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("delay %d ms (connection setup 200 ms)", ms)
	if ms == 0 || ms >= 150 {
		t.Fatalf("delay %d ms still includes the 200 ms connection setup", ms)
	}
}
