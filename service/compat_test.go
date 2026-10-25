package main

import (
	"errors"
	"strings"
	"testing"
)

func TestDropUnknownField(t *testing.T) {
	in := []byte(`{"dns":{"rules":[{"name":"x","server":"a"}]}}`)
	out, what, ok := dropUnknownField(in, errors.New(`decode: dns.rules[0].name: json: unknown field "name"`))
	if !ok || strings.Contains(string(out), `"name"`) || !strings.Contains(string(out), `"server":"a"`) {
		t.Fatalf("ok=%v what=%q out=%s", ok, what, out)
	}
	if _, _, ok := dropUnknownField(in, errors.New("some other error")); ok {
		t.Fatal("unrelated error must not change the config")
	}
}
