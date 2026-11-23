package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/brushknight/agents-deck/backend/internal/deskterm"
	"github.com/brushknight/agents-deck/backend/internal/model"
)

func paneInventory() deskterm.Inventory {
	var inv deskterm.Inventory
	if err := call("GET", "/admin/v1/terminals", nil, &inv); err != nil {
		fmt.Fprintln(os.Stderr, "Terminal location unavailable:", err)
	}
	return inv
}

func focusPane(host, id, mode, key string) error {
	var result struct{ Focused string }
	if err := call("POST", "/admin/v1/terminals/focus", map[string]string{"host": host, "id": id, "mode": mode, "key": key}, &result); err != nil {
		return err
	}
	fmt.Println("Focused", result.Focused)
	return nil
}

func attachSSH(ref string) error {
	var a model.Agent
	if err := runSSH(context.Background(), "show", ref, &a); err != nil {
		return err
	}
	inv := paneInventory()
	if p, ok := inv.Remote[a.ID]; ok {
		return focusPane(inv.Host, a.ID, "pane", p.Key())
	}
	return runSSH(context.Background(), "attach", a.ID, nil)
}

func focusCmd(args []string) error {
	fs := flag.NewFlagSet("focus", flag.ContinueOnError)
	remote := fs.Bool("ssh", false, "codebox session")
	tab := fs.Bool("tab", false, "select the tab and keep its active pane")
	hostTab := fs.Bool("host-tab", false, "select a codebox SSH tab without matching a thread")
	hostPane := fs.Bool("host-pane", false, "select a connected codebox SSH pane")
	link := fs.Bool("link-pane", false, "associate the specified thread with an existing codebox pane")
	unlink := fs.Bool("unlink-pane", false, "remove a manually linked pane")
	where := fs.String("location", "", "codebox window:tab:pane, for example 1:1:2")
	if err := fs.Parse(args); err != nil {
		return err
	}
	inv := paneInventory()
	panes := inv.HostPanes
	if *where != "" {
		panes = nil
		for _, p := range inv.HostPanes {
			if fmt.Sprintf("%d:%d:%d", p.Window, p.Tab, p.Pane) == *where {
				panes = append(panes, p)
			}
		}
	}
	if (*link || *unlink) && (!*remote || fs.NArg() != 1 || *link && *unlink || *hostPane || *hostTab) {
		return errors.New("use focus --ssh --link-pane ID or --unlink-pane ID")
	}
	if *hostTab || *hostPane {
		if !*remote || fs.NArg() != 0 || *hostTab && *hostPane {
			return errors.New("usage: agentctl focus --ssh --host-tab or --host-pane")
		}
		if len(panes) != 1 {
			return errors.New("choose a connected codebox pane with --location window:tab:pane")
		}
		mode := "host-tab"
		if *hostPane {
			mode = "host-pane"
		}
		return focusPane(inv.Host, "", mode, panes[0].Key())
	}
	if fs.NArg() != 1 {
		return errors.New("usage: agentctl focus [--ssh] [--tab] ID")
	}
	mode := "pane"
	if *tab {
		mode = "tab"
	}
	if *remote {
		var a model.Agent
		if err := runSSH(context.Background(), "show", fs.Arg(0), &a); err != nil {
			return err
		}
		p, ok := inv.Remote[a.ID]
		if *link || *unlink {
			action := "link"
			if *unlink {
				action = "unlink"
				if !ok || !p.Linked {
					return errors.New("this thread has no manual pane link")
				}
			} else {
				if len(panes) != 1 {
					return errors.New("choose the pane showing this thread with --location window:tab:pane")
				}
				p = panes[0]
			}
			if err := call("POST", "/admin/v1/terminals/link", map[string]string{"host": inv.Host, "id": a.ID, "key": p.Key(), "mode": action}, nil); err != nil {
				return err
			}
			fmt.Printf("Pane %s: %s\n", action, p.Label())
			return nil
		}
		if !ok {
			return errors.New("no confirmed pane for this thread; use agentctl attach --ssh ID to open it")
		}
		return focusPane(inv.Host, a.ID, mode, p.Key())
	}
	a, err := resolve(fs.Arg(0), "focus")
	if err != nil {
		return err
	}
	if p, ok := inv.Local[a.ID]; ok {
		return focusPane("", a.ID, mode, p.Key())
	}
	if *tab {
		return errors.New("no confirmed terminal tab for this session")
	}
	return call("POST", "/v1/agents/"+a.ID+"/focus", nil, nil)
}
