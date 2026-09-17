// Command api menjalankan REST API login pengguna dan CRUD jadwal tayang.
// Konfigurasi dibaca dari environment variable; lihat .env.example.
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/arikmhm/Backend_Test_MKP/internal/auth"
	"github.com/arikmhm/Backend_Test_MKP/internal/httpx"
	"github.com/arikmhm/Backend_Test_MKP/internal/showtime"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("api: %v", err)
	}
}

func run() error {
	var (
		databaseURL = os.Getenv("DATABASE_URL")
		jwtSecret   = os.Getenv("JWT_SECRET")
		port        = envOr("PORT", "8080")
		timezone    = envOr("APP_TIMEZONE", "Asia/Jakarta")
	)
	if databaseURL == "" {
		return errors.New("DATABASE_URL belum diisi")
	}

	tokenTTL, err := time.ParseDuration(envOr("TOKEN_TTL", "8h"))
	if err != nil {
		return errors.New("TOKEN_TTL bukan durasi yang sah, contoh: 8h")
	}

	signer, err := auth.NewSigner(jwtSecret, tokenTTL)
	if err != nil {
		return err
	}

	poolCfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return errors.New("DATABASE_URL tidak bisa dibaca: " + err.Error())
	}
	// Zona waktu sesi disamakan supaya penyaring ?date= berarti satu hari
	// penuh menurut jam setempat, bukan potongan hari menurut UTC.
	poolCfg.ConnConfig.RuntimeParams["timezone"] = timezone

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := pgxpool.NewWithConfig(ctx, poolCfg)
	if err != nil {
		return errors.New("membuka kolam koneksi gagal: " + err.Error())
	}
	defer pool.Close()

	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		return errors.New("database tidak bisa dihubungi: " + err.Error())
	}

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           requestLog(routes(pool, signer)),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		log.Printf("api: mendengarkan di http://localhost:%s (zona waktu %s, umur token %s)",
			port, timezone, tokenTTL)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("api: server berhenti: %v", err)
			stop()
		}
	}()

	<-ctx.Done()
	log.Print("api: sinyal berhenti diterima, menunggu permintaan berjalan selesai")

	shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancelShutdown()
	return srv.Shutdown(shutdownCtx)
}

// routes mendaftarkan seluruh endpoint. Pola "METODE /alamat/{id}" adalah
// routing bawaan net/http sejak Go 1.22.
func routes(pool *pgxpool.Pool, signer *auth.Signer) http.Handler {
	authHandler := auth.NewHandler(pool, signer)
	showtimeHandler := showtime.New(pool)

	authed := func(h http.HandlerFunc) http.Handler { return signer.RequireAuth(h) }
	adminOnly := func(h http.HandlerFunc) http.Handler {
		return signer.RequireAuth(auth.RequireAdmin(h))
	}

	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		httpx.OK(w, map[string]string{"status": "ok"})
	})

	mux.HandleFunc("POST /api/auth/login", authHandler.Login)
	mux.Handle("GET /api/auth/me", authed(authHandler.Me))

	mux.Handle("GET /api/showtimes", authed(showtimeHandler.List))
	mux.Handle("GET /api/showtimes/{id}", authed(showtimeHandler.Detail))
	mux.Handle("POST /api/showtimes", adminOnly(showtimeHandler.Create))
	mux.Handle("PUT /api/showtimes/{id}", adminOnly(showtimeHandler.Update))
	mux.Handle("DELETE /api/showtimes/{id}", adminOnly(showtimeHandler.Delete))

	return mux
}

func requestLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		log.Printf("%s %s -> %d (%s)", r.Method, r.URL.Path, rec.status,
			time.Since(started).Round(time.Millisecond))
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
