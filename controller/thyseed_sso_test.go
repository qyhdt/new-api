package controller

import (
	"testing"

	"github.com/QuantumNous/new-api/model"
)

func TestIsValidThyseedSsoUsername(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name  string
		input string
		ok    bool
	}{
		{"empty", "", false},
		{"legacy short", "admin", true},
		{"typical email", "zhangsan@thyseed.com", true},
		{"long corporate email", "abdelazizmohamedmousaahmedmousa@thyseed.com", true},
		{"too long", string(make([]byte, 129)), false},
		{"control char", "user\x00@thyseed.com", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := isValidThyseedSsoUsername(tc.input); got != tc.ok {
				t.Fatalf("isValidThyseedSsoUsername(%q) = %v, want %v", tc.input, got, tc.ok)
			}
		})
	}
}

func TestDeriveThyseedSsoDisplayName(t *testing.T) {
	t.Parallel()
	if got := deriveThyseedSsoDisplayName("fengshuangshuang@thyseed.com"); got != "fengshuangshuang" {
		t.Fatalf("got %q", got)
	}
	longLocal := "abdelazizmohamedmousaahmedmousa"
	if got := deriveThyseedSsoDisplayName(longLocal + "@thyseed.com"); len([]rune(got)) != model.DisplayNameMaxLength {
		t.Fatalf("expected display name truncated to %d runes, got %q", model.DisplayNameMaxLength, got)
	}
}
