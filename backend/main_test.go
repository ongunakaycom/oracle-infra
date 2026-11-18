package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestLoginLimiterBlocksAfterMaxFailures(t *testing.T) {
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	limiter := newLoginLimiter(3, time.Minute)
	limiter.now = func() time.Time { return now }

	for i := 0; i < 3; i++ {
		if wait := limiter.retryAfter("203.0.113.10"); wait != 0 {
			t.Fatalf("attempt %d unexpectedly blocked for %s", i+1, wait)
		}
		limiter.fail("203.0.113.10")
	}

	if wait := limiter.retryAfter("203.0.113.10"); wait != time.Minute {
		t.Fatalf("expected one minute lockout, got %s", wait)
	}

	// A different client must not be affected.
	if wait := limiter.retryAfter("203.0.113.11"); wait != 0 {
		t.Fatalf("expected other client to be allowed, got %s", wait)
	}

	// The window expires and the client is allowed again.
	now = now.Add(time.Minute)
	if wait := limiter.retryAfter("203.0.113.10"); wait != 0 {
		t.Fatalf("expected lockout to expire, got %s", wait)
	}
}

func TestLoginLimiterResetClearsFailures(t *testing.T) {
	limiter := newLoginLimiter(2, time.Minute)
	limiter.fail("198.51.100.7")
	limiter.fail("198.51.100.7")
	if wait := limiter.retryAfter("198.51.100.7"); wait == 0 {
		t.Fatal("expected client to be locked out")
	}

	limiter.reset("198.51.100.7")
	if wait := limiter.retryAfter("198.51.100.7"); wait != 0 {
		t.Fatalf("expected reset to clear lockout, got %s", wait)
	}
}

func TestClientIPOnlyTrustsForwardedForFromLoopback(t *testing.T) {
	spoofed := httptest.NewRequest(http.MethodPost, "/api/login", nil)
	spoofed.RemoteAddr = "203.0.113.50:4567"
	spoofed.Header.Set("X-Forwarded-For", "1.2.3.4")
	if got := clientIP(spoofed); got != "203.0.113.50" {
		t.Fatalf("expected direct peer address, got %s", got)
	}

	proxied := httptest.NewRequest(http.MethodPost, "/api/login", nil)
	proxied.RemoteAddr = "127.0.0.1:4567"
	proxied.Header.Set("X-Forwarded-For", "1.2.3.4, 203.0.113.50")
	if got := clientIP(proxied); got != "203.0.113.50" {
		t.Fatalf("expected proxy-appended address, got %s", got)
	}
}

func TestHandleLoginReturns429AfterRepeatedFailures(t *testing.T) {
	loginAttempts = newLoginLimiter(2, time.Minute)
	adminUser = "admin"
	adminPass = "correct-horse-battery-staple"
	t.Cleanup(func() {
		loginAttempts = newLoginLimiter(loginMaxAttempts, loginWindow)
	})

	body := `{"username":"admin","password":"wrong"}`
	post := func() *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(body))
		req.RemoteAddr = "203.0.113.99:1234"
		rec := httptest.NewRecorder()
		handleLogin(rec, req)
		return rec
	}

	for i := 0; i < 2; i++ {
		if rec := post(); rec.Code != http.StatusUnauthorized {
			t.Fatalf("attempt %d: expected 401, got %d", i+1, rec.Code)
		}
	}

	rec := post()
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429 after lockout, got %d", rec.Code)
	}
	if rec.Header().Get("Retry-After") == "" {
		t.Fatal("expected Retry-After header on throttled response")
	}
	var payload map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("failed to decode throttled payload: %v", err)
	}
	if payload["error"] == "" {
		t.Fatalf("expected error message, got %v", payload)
	}
}

func TestHandleLoginRejectsOversizedBody(t *testing.T) {
	loginAttempts = newLoginLimiter(5, time.Minute)

	huge := fmt.Sprintf(`{"username":%q,"password":"x"}`, strings.Repeat("a", 5000))
	req := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(huge))
	req.RemoteAddr = "203.0.113.100:1234"
	rec := httptest.NewRecorder()
	handleLogin(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for oversized body, got %d", rec.Code)
	}
}