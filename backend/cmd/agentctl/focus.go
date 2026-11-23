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
	if err := fs.Parse(args); err != nil {
		return err
	}
	inv := paneInventory()
	if *hostTab || *hostPane {
		if !*remote || fs.NArg() != 0 || *hostTab && *hostPane {
			return errors.New("usage: agentctl focus --ssh --host-tab or --host-pane")
		}
		if len(inv.HostPanes) != 1 {
			return errors.New("select a specific connected codebox tab in the dashboard")
		}
		mode := "host-tab"
		if *hostPane {
			mode = "host-pane"
		}
		return focusPane(inv.Host, "", mode, inv.HostPanes[0].Key())
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
