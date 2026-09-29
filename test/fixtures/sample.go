// Package widget exercises the Go symbol extractor.
package widget

import (
	"encoding/json"
	"fmt"
	"sync"
)

// MaxWidgets caps the store.
const MaxWidgets = 32

const defaultLabel = "widget"

// Mode is an iota-style enumeration.
type Mode int

const (
	ModeIdle Mode = iota
	ModeBusy
	ModeClosed
)

var registry = map[string]*Widget{}

var (
	ErrMissing = fmt.Errorf("missing widget")
	counter    int
)

// WidgetID is a defined type over string.
type WidgetID string

// Renderer is an alias kept for compatibility.
type Renderer = fmt.Stringer

// Transform maps one widget onto another.
type Transform func(w *Widget) *Widget

// Base carries fields shared by every widget.
type Base struct {
	ID    WidgetID `json:"id"`
	Label string   `json:"label"`
}

// Widget is the primary aggregate.
type Widget struct {
	Base
	*sync.Mutex
	Width  int
	Height int
	mode   Mode
}

// Store keeps widgets of one concrete type.
type Store[T any] struct {
	items []T
	mu    sync.RWMutex
}

// Displayable is implemented by anything renderable.
type Displayable interface {
	fmt.Stringer
	Display(w *Widget) error
	Bounds() (int, int)
}

// NewWidget builds a widget with defaults applied.
func NewWidget(id WidgetID) *Widget {
	return &Widget{Base: Base{ID: id, Label: defaultLabel}}
}

func init() {
	registry = make(map[string]*Widget, MaxWidgets)
}

// String implements fmt.Stringer.
func (w *Widget) String() string {
	return fmt.Sprintf("%s(%dx%d)", w.Label, w.Width, w.Height)
}

// Resize grows the widget.
func (w *Widget) Resize(width, height int) error {
	if width < 0 || height < 0 {
		return ErrMissing
	}
	w.Width, w.Height = width, height
	return nil
}

// Area reports the widget area from a value receiver.
func (w Widget) Area() int {
	return w.Width * w.Height
}

// MarshalJSON implements json.Marshaler.
func (w Widget) MarshalJSON() ([]byte, error) {
	return json.Marshal(w.Base)
}

// Add appends an item.
func (s *Store[T]) Add(item T) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.items = append(s.items, item)
}

// Fan spawns workers and collects their results.
func Fan(widgets []*Widget) <-chan string {
	out := make(chan string, len(widgets))
	done := make(chan struct{})
	for _, w := range widgets {
		go func(w *Widget) {
			out <- w.String()
		}(w)
	}
	select {
	case <-done:
	default:
	}
	close(out)
	return out
}

// Identity is generic over any comparable key.
func Identity[T comparable](value T) T {
	return value
}

func normalize(label string) string {
	if label == "" {
		return defaultLabel
	}
	return label
}
