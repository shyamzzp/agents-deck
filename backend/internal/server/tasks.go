// An agent's own tasks: the quick list on its card, beyond the eight every
// agent has. A prompt from the session's history is kept as one of these, so
// it can be sent again with a tap from any device the deck is paired with.

package server

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/shyamzzp/agents-deck/backend/internal/model"
	"github.com/shyamzzp/agents-deck/backend/internal/tasks"
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
	// A task made through the API is one a person made: the miner adds its own
	// with model.TaskMined, inside the service.
	t, err := s.Tasks.Add(id, in.Name, in.Text, model.TaskCustom, in.Slot)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	s.Store.Touch() // the clients redraw with the new tile on it
	writeJSON(w, http.StatusCreated, t)
}

// moveTask puts a task at a rank within its own band: the tasks someone made
// hold the front of the list and the mined ones follow, so a drag rearranges
// one among its own kind rather than across the two.
func (s *Server) moveTask(w http.ResponseWriter, r *http.Request) {
	if s.Tasks == nil {
		writeErr(w, http.StatusNotFound, "this deck keeps no tasks")
		return
	}
	var in struct {
		To int `json:"to"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<12)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "body must be {\"to\"}")
		return
	}
	if !s.Tasks.Move(r.PathValue("id"), r.PathValue("taskId"), in.To) {
		writeErr(w, http.StatusNotFound, "no such task")
		return
	}
	s.Store.Touch()
	w.WriteHeader(http.StatusNoContent)
}

// pinTask keeps a task through every rotation, or lets it rotate again.
func (s *Server) pinTask(w http.ResponseWriter, r *http.Request) {
	if s.Tasks == nil {
		writeErr(w, http.StatusNotFound, "this deck keeps no tasks")
		return
	}
	var in struct {
		Pinned *bool `json:"pinned"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<12)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "body must be {\"pinned\"}")
		return
	}
	pinned := in.Pinned == nil || *in.Pinned // no body at all means pin it
	if !s.Tasks.Pin(r.PathValue("id"), r.PathValue("taskId"), pinned) {
		writeErr(w, http.StatusNotFound, "no such task")
		return
	}
	s.Store.Touch()
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) removeTask(w http.ResponseWriter, r *http.Request) {
	if s.Tasks == nil || !s.Tasks.Remove(r.PathValue("id"), r.PathValue("taskId")) {
		writeErr(w, http.StatusNotFound, "no such task")
		return
	}
	s.Store.Touch()
	w.WriteHeader(http.StatusNoContent)
}
