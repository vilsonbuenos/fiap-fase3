package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func okHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
}

func do(t *testing.T, h http.Handler, method, body string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(method, "/auth/validate", strings.NewReader(body)))
	return rec
}

func TestChaosInactivePassesThrough(t *testing.T) {
	c := &chaos{}
	if got := do(t, c.wrap(okHandler()), http.MethodGet, "").Code; got != http.StatusOK {
		t.Fatalf("sem falha ativa esperava 200, veio %d", got)
	}
}

func TestChaosFullRateReturns500(t *testing.T) {
	c := &chaos{}
	if got := do(t, http.HandlerFunc(c.handler), http.MethodPost, `{"error_rate":1,"duration_seconds":60}`).Code; got != http.StatusOK {
		t.Fatalf("ativar falha: esperava 200, veio %d", got)
	}
	for i := 0; i < 20; i++ {
		if got := do(t, c.wrap(okHandler()), http.MethodGet, "").Code; got != http.StatusInternalServerError {
			t.Fatalf("com error_rate=1 esperava 500, veio %d", got)
		}
	}
	do(t, http.HandlerFunc(c.handler), http.MethodDelete, "")
	if got := do(t, c.wrap(okHandler()), http.MethodGet, "").Code; got != http.StatusOK {
		t.Fatalf("depois do DELETE esperava 200, veio %d", got)
	}
}

func TestChaosExpires(t *testing.T) {
	c := &chaos{errorRate: 1, until: time.Now().Add(-time.Second)}
	if got := do(t, c.wrap(okHandler()), http.MethodGet, "").Code; got != http.StatusOK {
		t.Fatalf("falha expirada deveria liberar a requisição, veio %d", got)
	}
}

func TestChaosRejectsInvalidBody(t *testing.T) {
	c := &chaos{}
	for _, body := range []string{`{"error_rate":0}`, `{"error_rate":1.5}`, `lixo`} {
		if got := do(t, http.HandlerFunc(c.handler), http.MethodPost, body).Code; got != http.StatusBadRequest {
			t.Fatalf("corpo %q: esperava 400, veio %d", body, got)
		}
	}
	if _, _, ok := c.active(); ok {
		t.Fatal("corpo inválido não deveria ativar a falha")
	}
}

func TestChaosEnabledFlag(t *testing.T) {
	t.Setenv("CHAOS_ENABLED", "true")
	if !chaosEnabled() {
		t.Fatal("CHAOS_ENABLED=true deveria habilitar")
	}
	t.Setenv("CHAOS_ENABLED", "")
	if chaosEnabled() {
		t.Fatal("sem CHAOS_ENABLED não deveria habilitar")
	}
}
