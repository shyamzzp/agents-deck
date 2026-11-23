package deskterm

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
)

// OpenCommand starts an argument vector in a new terminal without typing into an existing pane.
func OpenCommand(ctx context.Context, preferred, program string, argv ...string) error {
	script := `on run args
 set commandText to ""
 repeat with arg in args
  set commandText to commandText & " " & quoted form of (contents of arg)
 end repeat
 tell application "Terminal"
  do script commandText
  activate
 end tell
end run`
	if preferred == "iTerm2" {
		script = `on run args
 set commandText to ""
 repeat with arg in args
  set commandText to commandText & " " & quoted form of (contents of arg)
 end repeat
 tell application id "com.googlecode.iterm2"
  activate
  if (count of windows) is 0 then
   create window with default profile command commandText
  else
   tell current window to create tab with default profile command commandText
  end if
 end tell
end run`
	}
	args := append([]string{"-e", script, "--", program}, argv...)
	if out, err := exec.CommandContext(ctx, "/usr/bin/osascript", args...).CombinedOutput(); err != nil {
		return fmt.Errorf("opening %s: %w: %s", preferred, err, strings.TrimSpace(string(out)))
	}
	return nil
}
