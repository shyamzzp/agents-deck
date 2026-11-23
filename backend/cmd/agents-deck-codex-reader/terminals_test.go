package main

import "testing"

func TestRecordMatchRejectsSharedEvidence(t *testing.T) {
	links := map[string]string{}
	recordMatch(links, "shared", "one")
	recordMatch(links, "shared", "one")
	if links["shared"] != "one" {
		t.Fatal("same thread matched twice")
	}
	recordMatch(links, "shared", "two")
	recordMatch(links, "shared", "one")
	if links["shared"] != "" {
		t.Fatal("ambiguous evidence was reused")
	}
}
