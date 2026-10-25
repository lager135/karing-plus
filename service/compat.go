package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// Karing writes a few fields that only its own sing-box fork understands (for example dns.rules[].name).
// Standard sing-box rejects them with `<path>: json: unknown field "<name>"`. dropUnknownField removes the
// field the error points at, so the caller can decode again.

var reUnknownField = regexp.MustCompile(`([A-Za-z0-9_.\[\]]+): json: unknown field "([^"]+)"`)

// dropUnknownField returns the config without the field named in err, and a description of what was removed.
func dropUnknownField(content []byte, err error) ([]byte, string, bool) {
	m := reUnknownField.FindStringSubmatch(err.Error())
	if m == nil {
		return nil, "", false
	}
	path, field := m[1], m[2]
	var root any
	if json.Unmarshal(content, &root) != nil {
		return nil, "", false
	}
	// The path in the error ends with the field itself; walk to its parent object.
	segs := splitPath(path)
	if len(segs) > 0 && segs[len(segs)-1] == field {
		segs = segs[:len(segs)-1]
	}
	parent := root
	for _, s := range segs {
		switch node := parent.(type) {
		case map[string]any:
			parent = node[s]
		case []any:
			i, e := strconv.Atoi(s)
			if e != nil || i < 0 || i >= len(node) {
				return nil, "", false
			}
			parent = node[i]
		default:
			return nil, "", false
		}
	}
	obj, ok := parent.(map[string]any)
	if !ok {
		return nil, "", false
	}
	if _, has := obj[field]; !has {
		return nil, "", false
	}
	delete(obj, field)
	out, e := json.Marshal(root)
	if e != nil {
		return nil, "", false
	}
	return out, fmt.Sprintf("%s (%s)", path, field), true
}

// splitPath turns "dns.rules[0].name" into ["dns","rules","0","name"].
func splitPath(p string) []string {
	p = strings.ReplaceAll(p, "[", ".")
	p = strings.ReplaceAll(p, "]", "")
	var out []string
	for _, s := range strings.Split(p, ".") {
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}

// normalizeKaring rewrites Karing-only shapes into standard sing-box fields before decoding.
func normalizeKaring(m map[string]any) {
	dns, _ := m["dns"].(map[string]any)
	if dns == nil {
		return
	}
	servers, _ := dns["servers"].([]any)
	for _, s := range servers {
		srv, _ := s.(map[string]any)
		if srv == nil {
			continue
		}
		// Karing: "addresses": [a, b] (tried in order). sing-box: one "address"; keep the first.
		if list, ok := srv["addresses"].([]any); ok {
			if _, has := srv["address"]; !has {
				for _, a := range list {
					if str, ok := a.(string); ok && str != "" {
						srv["address"] = str
						break
					}
				}
			}
			delete(srv, "addresses")
		}
	}
	rules, _ := dns["rules"].([]any)
	for _, r := range rules {
		if rule, ok := r.(map[string]any); ok {
			delete(rule, "name")
		}
	}
}
