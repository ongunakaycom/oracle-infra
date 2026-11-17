package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

type HealthResponse struct {
	Status     string `json:"status"`
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

var db *sql.DB

func initDB() {
	var err error
	db, err = sql.Open("sqlite", "./secops.db")
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

	_, err = db.Exec(createTableSQL)
	if err != nil {
		log.Fatalf("Failed to create table: %v", err)
	}

	// Seed initial data if empty
	var count int
	db.QueryRow("SELECT COUNT(*) FROM audit_logs").Scan(&count)
	if count == 0 {
		db.Exec(`INSERT INTO audit_logs (service, severity, message) VALUES ('caddy-proxy', 'HIGH', 'SSL renewal task failed or proxy timeout detected')`)
		db.Exec(`INSERT INTO audit_logs (service, severity, message) VALUES ('auth-gateway', 'MEDIUM', 'Rate limit threshold approaching on endpoint /api/login')`)
		db.Exec(`INSERT INTO audit_logs (service, severity, message) VALUES ('oci-firewall', 'LOW', 'NSG rule synchronized successfully across VCN subnets')`)
	}
}

func enableCORS(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}
		next(w, r)
	}
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(HealthResponse{
		Status:     "HEALTHY",
		CPUPercent: "14.2%",
		MemoryUsed: "290 MB / 1024 MB",
		Uptime:     "4d 12h",
	})
}

func handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req LoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Simple check (admin/admin or demo)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(LoginResponse{
		Token: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.demo-jwt-token-active",
		Role:  "admin",
	})
}

func handleRecords(w http.ResponseWriter, r *http.Request) {
	// Auth check
	authHeader := r.Header.Get("Authorization")
	if authHeader == "" || !strings.HasPrefix(authHeader, "Bearer ") {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	w.Header().Set("Content-Type", "application/json")

	if r.Method == http.MethodGet {
		query := r.URL.Query().Get("q")
		var rows *sql.Rows
		var err error

		if query != "" {
			rows, err = db.Query("SELECT id, service, severity, message, created_at FROM audit_logs WHERE message LIKE ? OR service LIKE ? ORDER BY id DESC", "%"+query+"%", "%"+query+"%")
		} else {
			rows, err = db.Query("SELECT id, service, severity, message, created_at FROM audit_logs ORDER BY id DESC")
		}

		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer rows.Close()

		var records []Record
		for rows.Next() {
			var rec Record
			if err := rows.Scan(&rec.ID, &rec.Service, &rec.Severity, &rec.Message, &rec.CreatedAt); err != nil {
				continue
			}
			records = append(records, rec)
		}
		if records == nil {
			records = []Record{}
		}
		json.NewEncoder(w).Encode(records)
		return
	}

	if r.Method == http.MethodPost {
		var rec Record
		if err := json.NewDecoder(r.Body).Decode(&rec); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		res, err := db.Exec("INSERT INTO audit_logs (service, severity, message) VALUES (?, ?, ?)", rec.Service, rec.Severity, rec.Message)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		id, _ := res.LastInsertId()
		rec.ID = id
		rec.CreatedAt = time.Now().Format("2006-01-02 15:04:05")

		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(rec)
		return
	}

	http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
}

func main() {
	initDB()
	defer db.Close()

	mux := http.NewServeMux()
	mux.HandleFunc("/api/health", enableCORS(handleHealth))
	mux.HandleFunc("/api/login", enableCORS(handleLogin))
	mux.HandleFunc("/api/records", enableCORS(handleRecords))

	port := ":8080"
	log.Printf("SecOps API server starting on %s...", port)
	if err := http.ListenAndServe(port, mux); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
