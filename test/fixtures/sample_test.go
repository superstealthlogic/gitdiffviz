package widget

import "testing"

func TestResize(t *testing.T) {
	w := NewWidget("a")

	t.Run("rejects negative width", func(t *testing.T) {
		if err := w.Resize(-1, 2); err == nil {
			t.Fatal("expected an error")
		}
	})

	t.Run("stores the new size", func(t *testing.T) {
		if err := w.Resize(3, 4); err != nil {
			t.Fatal(err)
		}
	})
}

func TestArea(t *testing.T) {
	if got := (Widget{Width: 2, Height: 3}).Area(); got != 6 {
		t.Fatalf("area = %d", got)
	}
}

func BenchmarkResize(b *testing.B) {
	w := NewWidget("b")
	for i := 0; i < b.N; i++ {
		_ = w.Resize(i, i)
	}
}

func FuzzNormalize(f *testing.F) {
	f.Fuzz(func(t *testing.T, label string) {
		_ = normalize(label)
	})
}

func ExampleNewWidget() {
	_ = NewWidget("example")
	// Output:
}

func helper(t *testing.T) *Widget {
	t.Helper()
	return NewWidget("helper")
}
