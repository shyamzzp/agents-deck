// An agent's own tasks: the quick list on its card, beyond the eight every
// agent has. A prompt from the session's history is kept as one of these, so
// it can be sent again with a tap from any device the deck is paired with.

package server

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/brushknight/agents-deck/backend/internal/tasks"
)

func (s *Server) getTasks(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, ok := s.Store.Get(id); !ok {
		writeErr(w, http.StatusNotFound, ErrNotFound.Error())
		return
	}
	out := []tasks.Task{}
	if s.Tasks != nil {
		out = append(out, s.Tasks.List(id)...)
	}
	writeJSON(w, http.StatusOK, map[string]any{"tasks": out})
}

func (s *Server) addTask(w http.ResponseWriter, r *http.Request) {
	if s.Tasks == nil {
		writeErr(w, http.StatusNotFound, "this deck keeps no tasks")
		return
	}
	id := r.PathValue("id")
	if _, ok := s.Store.Get(id); !ok {
		writeErr(w, http.StatusNotFound, ErrNotFound.Error())
		return
	}
	var in struct {
		Name string `json:"name"`
		Text string `json:"text"`
		Slot int    `json:"slot"` // the cell of the board it was made in
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "body must be {\"text\", \"name\"}")
		return
	}
	if strings.TrimSpace(in.Text) == "" {
		writeErr(w, http.StatusBadRequest, tasks.ErrEmpty.Error())
		return
	}
	t, err := s.Tasks.Add(id, in.Name, in.Text, in.Slot)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	s.Store.Touch() // the clients redraw with the new tile on it
	writeJSON(w, http.StatusCreated, t)
}

func (s *Server) removeTask(w http.ResponseWriter, r *http.Request) {
	if s.Tasks == nil || !s.Tasks.Remove(r.PathValue("id"), r.PathValue("taskId")) {
		writeErr(w, http.StatusNotFound, "no such task")
		return
	}
	s.Store.Touch()
	w.WriteHeader(http.StatusNoContent)
}
