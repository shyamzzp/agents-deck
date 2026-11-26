// A list the deck keeps ready.
//
// Some of what the deck shows is read rather than watched: the artifacts page
// is a sweep of every transcript on the Mac, which is cheap once the files
// are remembered and a second when they are not. Nobody should wait a second
// for a page to open, and nobody should see yesterday's list either.
//
// kept holds such a list: built once when it is first wanted, and rebuilt in
// the background off the daemon's tick from then on, so a page is always
// served from what the last sweep found. Any page of the same shape later on
// can be kept the same way.
package daemon

import (
	"sync"
	"time"
)

type kept[T any] struct {
	mu    sync.Mutex
	val   T
	at    time.Time
	busy  bool
	every time.Duration
	build func() T
}

func newKept[T any](every time.Duration, build func() T) *kept[T] {
	return &kept[T]{every: every, build: build}
}

// get is the list as the last sweep left it. The first caller waits for a
// sweep because there is nothing to show yet; no one after that ever does.
func (k *kept[T]) get() T {
	k.mu.Lock()
	if !k.at.IsZero() {
		v := k.val
		k.mu.Unlock()
		return v
	}
	k.mu.Unlock()

	v := k.build()
	k.mu.Lock()
	k.val, k.at = v, time.Now()
	k.mu.Unlock()
	return v
}

// now starts a sweep whatever the clock says: something happened that the
// list is meant to show, and it should show it rather than wait its turn.
func (k *kept[T]) now() {
	k.mu.Lock()
	k.at = time.Time{}
	k.mu.Unlock()
	k.due()
}

// due starts a sweep when the list has gone stale, and returns at once. One
// sweep runs at a time: a slow one does not pile up behind the tick.
func (k *kept[T]) due() {
	k.mu.Lock()
	if k.busy || (!k.at.IsZero() && time.Since(k.at) < k.every) {
		k.mu.Unlock()
		return
	}
	k.busy = true
	k.mu.Unlock()

	go func() {
		v := k.build()
		k.mu.Lock()
		k.val, k.at, k.busy = v, time.Now(), false
		k.mu.Unlock()
	}()
}
