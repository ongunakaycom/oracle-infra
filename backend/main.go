package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

// HealthResponse is the public liveness payload. It intentionally carries no
// system telemetry so unauthenticated clients cannot fingerprint the host.
type HealthResponse struct {
	Status string `json:"status"`
}

// MetricsResponse is only served to authenticated operators.
type MetricsResponse struct {
	CPUPercent string `json:"cpu_percent"`
	MemoryUsed string `json:"memory_used"`
	Uptime     string `json:"uptime"`
}

type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type LoginResponse struct {
	Token string `json:"token"`
	Role  string `json:"role"`
}

type Record struct {
	ID        int64  `json:"id"`
	Service   string `json:"service"`
	Severity  string `json:"severity"`
	Message   string `json:"message"`
	CreatedAt string `json:"created_at"`
}

type tokenClaims struct {
	Sub  string `json:"sub"`
	Role string `json:"role"`
	Iat  int64  `json:"iat"`
	Exp  int64  `json:"exp"`
}

const tokenTTL = 8 * time.Hour

var (
	db *sql.DB

	adminUser string
	adminPass string
	jwtSecret []byte

	cpuMu      sync.Mutex
	prevBusy   uint64
	prevTotal  uint64
	prevSample bool
)

func writeJSON(w http.ResponseWriter, status int, payload interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("failed to encode response: %v", err)
	}
}

func loadConfig() {
	adminUser = os.Getenv("SECOPS_ADMIN_USER")
	adminPass = os.Getenv("SECOPS_ADMIN_PASS")
	secret := os.Getenv("SECOPS_JWT_SECRET")

	if adminUser == "" || adminPass == "" || secret == "" {
		log.Fatal("missing required environment variables: SECOPS_ADMIN_USER, SECOPS_ADMIN_PASS, SECOPS_JWT_SECRET")
	}
	jwtSecret = []byte(secret)
}

func initDB() {
	var err error
	dbPath := os.Getenv("SECOPS_DB_PATH")
	if dbPath == "" {
		dbPath = "./secops.db"
	}

	db, err = sql.Open("sqlite", dbPath)
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}

	createTableSQL := `
	CREATE TABLE IF NOT EXISTS audit_logs (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		service TEXT,
		severity TEXT,
		message TEXT,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	);`

	if _, err = db.Exec(createTableSQL); err != nil {
		log.Fatalf("Failed to create table: %v", err)
	}
}

func insertAudit(service, severity, message string) {
	if _, err := db.Exec(
		"INSERT INTO audit_logs (service, severity, message) VALUES (?, ?, ?)",
		service, severity, message,
	); err != nil {
		log.Printf("failed to insert audit record: %v", err)
	}
}

func enableCORS(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		// Production domain plus local development origins only.
		if origin == "https://oracle-infra.duckdns.org" || strings.HasPrefix(origin, "http://localhost:") {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
		}
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next(w, r)
	}
}

// ---- JWT (HS256) -----------------------------------------------------------

func base64URL(data []byte) string {
	return base64.RawURLEncoding.EncodeToString(data)
}

func signToken(subject, role string) (string, error) {
	header := base64URL([]byte(`{"alg":"HS256","typ":"JWT"}`))
	now := time.Now()
	payload, err := json.Marshal(tokenClaims{
		Sub:  subject,
		Role: role,
		Iat:  now.Unix(),
		Exp:  now.Add(tokenTTL).Unix(),
	})
	if err != nil {
		return "", err
	}

	signingInput := header + "." + base64URL(payload)
	mac := hmac.New(sha256.New, jwtSecret)
	mac.Write([]byte(signingInput))
	return signingInput + "." + base64URL(mac.Sum(nil)), nil
}

func verifyToken(token string) (tokenClaims, error) {
	var claims tokenClaims

	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return claims, errors.New("malformed token")
	}

	signingInput := parts[0] + "." + parts[1]
	mac := hmac.New(sha256.New, jwtSecret)
	mac.Write([]byte(signingInput))
	expected := base64URL(mac.Sum(nil))
	if subtle.ConstantTimeCompare([]byte(expected), []byte(parts[2])) != 1 {
		return claims, errors.New("invalid signature")
	}

	headerJSON, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return claims, errors.New("malformed header")
	}
	var header struct {
		Alg string `json:"alg"`
	}
	if err := json.Unmarshal(headerJSON, &header); err != nil || header.Alg != "HS256" {
		return claims, errors.New("unsupported algorithm")
	}

	payloadJSON, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return claims, errors.New("malformed payload")
	}
	if err := json.Unmarshal(payloadJSON, &claims); err != nil {
		return claims, errors.New("invalid claims")
	}
	if claims.Exp <= time.Now().Unix() {
		return claims, errors.New("token expired")
	}
	return claims, nil
}

func requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "authorization required"})
			return
		}

		claims, err := verifyToken(strings.TrimSpace(strings.TrimPrefix(header, "Bearer ")))
		if err != nil {
			log.Printf("rejected request to %s: %v", r.URL.Path, err)
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid or expired token"})
			return
		}
		if claims.Role != "admin" {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "insufficient privileges"})
			return
		}
		next(w, r)
	}
}

// ---- System telemetry ------------------------------------------------------

func readCPUSample() (busy, total uint64, err error) {
	raw, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0, 0, err
	}

	for _, line := range strings.Split(string(raw), "\n") {
		if !strings.HasPrefix(line, "cpu ") {
			continue
		}
		fields := strings.Fields(line)[1:]
		values := make([]uint64, 0, len(fields))
		for _, field := range fields {
			v, parseErr := strconv.ParseUint(field, 10, 64)
			if parseErr != nil {
				return 0, 0, parseErr
			}
			values = append(values, v)
		}
		if len(values) < 4 {
			return 0, 0, errors.New("unexpected /proc/stat layout")
		}

		idle := values[3]
		if len(values) > 4 {
			idle += values[4] // iowait counts as idle time
		}
		for _, v := range values {
			total += v
		}
		return total - idle, total, nil
	}
	return 0, 0, errors.New("cpu statistics not found")
}

func cpuPercent() float64 {
	cpuMu.Lock()
	defer cpuMu.Unlock()

	busy, total, err := readCPUSample()
	if err != nil {
		return 0
	}

	var pct float64
	if prevSample && total > prevTotal && busy >= prevBusy {
		pct = float64(busy-prevBusy) / float64(total-prevTotal) * 100
	} else if total > 0 {
		pct = float64(busy) / float64(total) * 100
	}

	prevBusy, prevTotal, prevSample = busy, total, true
	return math.Round(pct*10) / 10
}

func memoryUsage() (usedMB, totalMB uint64) {
	raw, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0, 0
	}

	var totalKB, availableKB uint64
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		value, parseErr := strconv.ParseUint(fields[1], 10, 64)
		if parseErr != nil {
			continue
		}
		switch fields[0] {
		case "MemTotal:":
			totalKB = value
		case "MemAvailable:":
			availableKB = value
		}
	}
	if totalKB == 0 || availableKB > totalKB {
		return 0, 0
	}
	return (totalKB - availableKB) / 1024, totalKB / 1024
}

func systemUptime() string {
	raw, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return "unknown"
	}
	fields := strings.Fields(string(raw))
	if len(fields) == 0 {
		return "unknown"
	}
	seconds, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return "unknown"
	}

	total := int64(seconds)
	return fmt.Sprintf("%dd %dh %dm", total/86400, (total%86400)/3600, (total%3600)/60)
}

func clientIP(r *http.Request) string {
	if forwarded := r.Header.Get("X-Forwarded-For"); forwarded != "" {
		if first := strings.TrimSpace(strings.Split(forwarded, ",")[0]); first != "" {
			return first
		}
	}
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
}

// ---- Handlers --------------------------------------------------------------

func handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, HealthResponse{Status: "HEALTHY"})
}

func handleMetrics(w http.ResponseWriter, r *http.Request) {
	usedMB, totalMB := memoryUsage()
	writeJSON(w, http.StatusOK, MetricsResponse{
		CPUPercent: fmt.Sprintf("%.1f%%", cpuPercent()),
		MemoryUsed: fmt.Sprintf("%d MB / %d MB", usedMB, totalMB),
		Uptime:     systemUptime(),
	})
}

func handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	var req LoginRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	userOK := subtle.ConstantTimeCompare([]byte(req.Username), []byte(adminUser)) == 1
	passOK := subtle.ConstantTimeCompare([]byte(req.Password), []byte(adminPass)) == 1
	if !userOK || !passOK {
		log.Printf("failed operator login attempt from %s", clientIP(r))
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid credentials"})
		return
	}

	token, err := signToken(adminUser, "admin")
	if err != nil {
		log.Printf("failed to sign token: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "authentication unavailable"})
		return
	}

	insertAudit("auth-gateway", "INFO", "Operator login succeeded from "+clientIP(r))
	writeJSON(w, http.StatusOK, LoginResponse{Token: token, Role: "admin"})
}

func handleRecords(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		query := strings.TrimSpace(r.URL.Query().Get("q"))

		var (
			rows *sql.Rows
			err  error
		)
		if query != "" {
			like := "%" + query + "%"
			rows, err = db.Query(
				"SELECT id, service, severity, message, created_at FROM audit_logs WHERE message LIKE ? OR service LIKE ? ORDER BY id DESC LIMIT 200",
				like, like,
			)
		} else {
			rows, err = db.Query(
				"SELECT id, service, severity, message, created_at FROM audit_logs ORDER BY id DESC LIMIT 200",
			)
		}
		if err != nil {
			log.Printf("failed to query audit logs: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "query failed"})
			return
		}
		defer rows.Close()

		records := make([]Record, 0, 32)
		for rows.Next() {
			var rec Record
			if err := rows.Scan(&rec.ID, &rec.Service, &rec.Severity, &rec.Message, &rec.CreatedAt); err != nil {
				log.Printf("failed to scan audit record: %v", err)
				continue
			}
			records = append(records, rec)
		}
		writeJSON(w, http.StatusOK, records)

	case http.MethodPost:
		var rec Record
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&rec); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
			return
		}

		rec.Service = strings.TrimSpace(rec.Service)
		rec.Severity = strings.ToUpper(strings.TrimSpace(rec.Severity))
		rec.Message = strings.TrimSpace(rec.Message)

		if rec.Service == "" || rec.Message == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "service and message are required"})
			return
		}
		switch rec.Severity {
		case "INFO", "LOW", "MEDIUM", "HIGH":
		case "":
			rec.Severity = "INFO"
		default:
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "severity must be INFO, LOW, MEDIUM or HIGH"})
			return
		}

		res, err := db.Exec(
			"INSERT INTO audit_logs (service, severity, message) VALUES (?, ?, ?)",
			rec.Service, rec.Severity, rec.Message,
		)
		if err != nil {
			log.Printf("failed to insert audit record: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "insert failed"})
			return
		}

		rec.ID, _ = res.LastInsertId()
		rec.CreatedAt = time.Now().UTC().Format(time.RFC3339)
		writeJSON(w, http.StatusCreated, rec)

	default:
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
	}
}

func main() {
	loadConfig()
	initDB()
	defer db.Close()

	insertAudit("secops-api", "INFO", "SecOps API service started")

	mux := http.NewServeMux()
	mux.HandleFunc("/api/health", enableCORS(handleHealth))
	mux.HandleFunc("/api/metrics", enableCORS(requireAuth(handleMetrics)))
	mux.HandleFunc("/api/login", enableCORS(handleLogin))
	mux.HandleFunc("/api/records", enableCORS(requireAuth(handleRecords)))

	port := ":8080"
	log.Printf("SecOps API server starting on %s", port)
	server := &http.Server{
		Addr:              port,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}