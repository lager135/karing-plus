package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const maxConfigBytes = 64 << 20

// zapretUnsupported answers the zapret endpoints on systems without the zapret backend.
func zapretUnsupported(w http.ResponseWriter) bool {
	if zapretSupported {
		return false
	}
	reply(w, 501, map[string]any{"error": "zapret is not supported on this system", "running": false})
	return true
}

func readSecret() (string, error) {
	b, err := os.ReadFile(secretPath())
	if err != nil {
		return "", err
	}
	s := strings.TrimSpace(string(b))
	if !reSecret.MatchString(s) {
		return "", errors.New("stored secret is invalid; reinstall the service")
	}
	return s, nil
}

func sameSecret(a, b string) bool {
	ha, hb := sha256.Sum256([]byte(a)), sha256.Sum256([]byte(b))
	return subtle.ConstantTimeCompare(ha[:], hb[:]) == 1
}

func reply(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func newHandler(secret string, c *core, z *zapret) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /zapret/state", func(w http.ResponseWriter, r *http.Request) {
		if zapretUnsupported(w) {
			return
		}
		on, port, token := z.info()
		reply(w, 200, map[string]any{"running": on, "port": port, "token": token})
	})
	mux.HandleFunc("POST /zapret/start", func(w http.ResponseWriter, r *http.Request) {
		if zapretUnsupported(w) {
			return
		}
		if err := z.start(); err != nil {
			reply(w, 500, map[string]string{"error": err.Error()})
			return
		}
		reply(w, 200, map[string]bool{"running": true})
	})
	mux.HandleFunc("POST /zapret/stop", func(w http.ResponseWriter, r *http.Request) {
		if zapretUnsupported(w) {
			return
		}
		z.stop()
		reply(w, 200, map[string]bool{"running": false})
	})
	mux.HandleFunc("GET /version", func(w http.ResponseWriter, r *http.Request) {
		reply(w, 200, map[string]string{"version": version})
	})
	mux.HandleFunc("GET /state", func(w http.ResponseWriter, r *http.Request) {
		st, e := c.state()
		reply(w, 200, map[string]string{"state": st, "error": e})
	})
	mux.HandleFunc("POST /start", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxConfigBytes))
		if err != nil {
			reply(w, 400, map[string]string{"error": "config too large or unreadable"})
			return
		}
		if err := c.start(body); err != nil {
			reply(w, 500, map[string]string{"error": err.Error()})
			return
		}
		reply(w, 200, map[string]string{"state": "connected"})
	})
	mux.HandleFunc("POST /stop", func(w http.ResponseWriter, r *http.Request) {
		c.stop()
		reply(w, 200, map[string]string{"state": "disconnected"})
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Browsers can reach 127.0.0.1 too: refuse anything that looks like a web page request.
		if r.Header.Get("Origin") != "" {
			reply(w, 403, map[string]string{"error": "forbidden"})
			return
		}
		h := r.Header.Get("Authorization")
		if !strings.HasPrefix(h, "Bearer ") || !sameSecret(strings.TrimPrefix(h, "Bearer "), secret) {
			reply(w, 401, map[string]string{"error": "unauthorized"})
			return
		}
		mux.ServeHTTP(w, r)
	})
}

// serve runs the control server until ctx ends, then stops the core.
func serve(ctx context.Context) error {
	secret, err := readSecret()
	if err != nil {
		return err
	}
	logf, _ := os.OpenFile(filepath.Join(dataDir(), "service.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if logf != nil {
		log.SetOutput(logf)
		defer logf.Close()
	}
	c := &core{}
	z := &zapret{}
	srv := &http.Server{Addr: listenAddr, Handler: newHandler(secret, c, z), ReadHeaderTimeout: 10 * time.Second}
	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	log.Printf("karingService %s listening on %s", version, listenAddr)
	select {
	case <-ctx.Done():
	case err = <-errc:
	}
	sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(sctx)
	c.stop()
	z.stop()
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
