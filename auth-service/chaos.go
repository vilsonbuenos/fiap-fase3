package main

import (
	"encoding/json"
	"math/rand/v2"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// Injeção de falha (Fase 4 - demonstração do Self-Healing).
//
// Simula o incidente do enunciado: o serviço "falha silenciosamente" — o
// /auth/health continua 200 (liveness/readiness não percebem nada), mas uma
// fração das requisições de negócio devolve 500. O estado vive só na memória
// do processo, então o `kubectl rollout restart` disparado pelo self-healing
// sobe pods limpos e de fato resolve o problema.
//
// Só existe quando CHAOS_ENABLED=true, e o endpoint exige a MASTER_KEY:
//
//	POST   /auth/admin/chaos  {"error_rate": 1.0, "duration_seconds": 900}
//	GET    /auth/admin/chaos  -> estado atual
//	DELETE /auth/admin/chaos  -> desliga
type chaos struct {
	mu        sync.RWMutex
	errorRate float64
	until     time.Time
}

type chaosRequest struct {
	ErrorRate       float64 `json:"error_rate"`
	DurationSeconds int     `json:"duration_seconds"`
}

func chaosEnabled() bool {
	return strings.EqualFold(os.Getenv("CHAOS_ENABLED"), "true")
}

func (c *chaos) active() (float64, time.Time, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.errorRate <= 0 || time.Now().After(c.until) {
		return 0, time.Time{}, false
	}
	return c.errorRate, c.until, true
}

// wrap devolve 500 para uma fração das requisições enquanto a falha estiver ativa.
func (c *chaos) wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if rate, _, ok := c.active(); ok && rand.Float64() < rate {
			logf(r.Context(), "CHAOS: falha injetada em %s %s (error_rate=%.2f)", r.Method, r.URL.Path, rate)
			http.Error(w, "Erro interno (falha injetada)", http.StatusInternalServerError)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (c *chaos) handler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		var req chaosRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ErrorRate <= 0 || req.ErrorRate > 1 {
			http.Error(w, `Corpo inválido: {"error_rate": (0,1], "duration_seconds": N}`, http.StatusBadRequest)
			return
		}
		if req.DurationSeconds <= 0 {
			req.DurationSeconds = 900
		}
		c.mu.Lock()
		c.errorRate = req.ErrorRate
		c.until = time.Now().Add(time.Duration(req.DurationSeconds) * time.Second)
		c.mu.Unlock()
		logf(r.Context(), "CHAOS: falha ATIVADA (error_rate=%.2f por %ds)", req.ErrorRate, req.DurationSeconds)
	case http.MethodDelete:
		c.mu.Lock()
		c.errorRate, c.until = 0, time.Time{}
		c.mu.Unlock()
		logf(r.Context(), "CHAOS: falha DESATIVADA")
	case http.MethodGet:
	default:
		http.Error(w, "Método não permitido", http.StatusMethodNotAllowed)
		return
	}

	rate, until, ok := c.active()
	resp := map[string]any{"active": ok, "error_rate": rate}
	if ok {
		resp["until"] = until.UTC().Format(time.RFC3339)
	}
	hostname, _ := os.Hostname()
	resp["pod"] = hostname
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}
