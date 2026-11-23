package sshdeck

import (
	"crypto/sha256"
	"fmt"
	"strings"
)

// TitleKey keeps session text out of terminal discovery responses. The prefix
// distinguishes title evidence from legacy SSH connection endpoint keys.
func TitleKey(title string) string {
	return fmt.Sprintf("title:%x", sha256.Sum256([]byte(strings.TrimSpace(title))))
}
