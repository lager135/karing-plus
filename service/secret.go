package main

import (
	"path/filepath"
	"regexp"
)

var reSecret = regexp.MustCompile(`^[0-9a-fA-F]{32,128}$`)

func secretPath() string { return filepath.Join(dataDir(), "secret") }
