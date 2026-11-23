package admin

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMessageRoutesLiteralTextToSelectedAgent(t *testing.T) {
	const msg = `Check "$HOME"; $(date)`
	calls := 0
	a := &Admin{SendMessage: func(ctx context.Context, id, text string) error {
		calls++
		if id != "selected" || text != msg {
			t.Fatalf("wrong destination or text")
		}
		return nil
	}}
	for _, tc := range []struct {
		host, text string
		want       int
	}{{"", msg, 200}, {"", "line\nbreak", 400}, {"", "  ", 400}, {"other-host", msg, 409}} {
		raw, _ := json.Marshal(map[string]string{"id": "selected", "host": tc.host, "text": tc.text})
		w := httptest.NewRecorder()
		a.message(w, httptest.NewRequest("POST", "/admin/v1/agents/message", strings.NewReader(string(raw))))
		if w.Code != tc.want {
			t.Fatalf("got %d, want %d", w.Code, tc.want)
		}
	}
	if calls != 1 {
		t.Fatalf("unexpected sends: %d", calls)
	}
}
