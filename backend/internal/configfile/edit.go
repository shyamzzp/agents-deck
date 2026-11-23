// Package configfile serializes read-modify-write operations on the daemon configuration.
package configfile

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

var mu sync.Mutex

func Edit(path string, fn func(map[string]any) error) error {
	mu.Lock()
	defer mu.Unlock()
	cfg := map[string]any{}
	if b, err := os.ReadFile(path); err == nil {
		if err := json.Unmarshal(b, &cfg); err != nil {
			return fmt.Errorf("config.json is not valid JSON: %v", err)
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if cfg == nil {
		cfg = map[string]any{}
	}
	if err := fn(cfg); err != nil {
		return err
	}
	b, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
