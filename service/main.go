// karingService: privileged core service for Karing+ (Windows service or Linux systemd unit).
//
// The service runs the sing-box core as LocalSystem (Windows) or root (Linux), so the TUN inbound
// can create its adapter and set routes while the Karing+ app itself runs without admin rights.
// The app talks to it over HTTP on 127.0.0.1 with a bearer secret chosen at install time.
//
// Commands:
//
//	karingService install -secret-file <path> (elevated) create and start the service
//	karingService uninstall               (elevated) stop and delete the service
//	karingService run                     run in the foreground (debugging, needs admin/root for TUN)
//	karingService check <config.json>     decode and create the core without starting it
//	karingService version
//
// Windows-only code lives in *_windows.go, Linux-only code in *_linux.go.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
)

const (
	serviceDisplay = "Karing+ Core Service"
	serviceDesc    = "Runs the Karing+ VPN core (sing-box) and its TUN adapter."
	listenAddr     = "127.0.0.1:44781"
	version        = "1.0.0"
)

func main() {
	if len(os.Args) < 2 {
		if startedByServiceManager() {
			runService()
			return
		}
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "install":
		fs := flag.NewFlagSet("install", flag.ExitOnError)
		secret := fs.String("secret", "", "bearer secret the app will use (hex, 32..128 chars)")
		secretFile := fs.String("secret-file", "", "read the secret from this file instead of the command line")
		_ = fs.Parse(os.Args[2:])
		if *secretFile != "" {
			b, err := os.ReadFile(*secretFile)
			if err != nil {
				log.Fatalf("install: read secret file: %v", err)
			}
			*secret = strings.TrimSpace(string(b))
		}
		if err := install(*secret); err != nil {
			log.Fatalf("install: %v", err)
		}
		fmt.Println("installed")
	case "uninstall":
		if err := uninstall(); err != nil {
			log.Fatalf("uninstall: %v", err)
		}
		fmt.Println("uninstalled")
	case "run":
		if err := runForeground(); err != nil {
			log.Fatal(err)
		}
	case "service":
		runService()
	case "core":
		// Started by the service: runs one sing-box core (see core.go).
		runCoreChild()
	case "check":
		// karingService check <config.json>: decode and create the core without starting it.
		if len(os.Args) < 3 {
			usage()
			os.Exit(2)
		}
		if err := checkConfig(os.Args[2]); err != nil {
			fmt.Println("FAIL:", err)
			os.Exit(1)
		}
		fmt.Println("OK")
	case "version":
		fmt.Println(version)
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, usageText)
}
