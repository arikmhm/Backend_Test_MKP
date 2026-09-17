package auth

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"

	"github.com/arikmhm/Backend_Test_MKP/internal/httpx"
)

// dummyHash adalah hash bcrypt dari kata sandi yang tidak pernah dipakai.
// Saat email tidak ditemukan, kata sandi tetap dibandingkan dengan hash ini.
// bcrypt sengaja lambat, jadi tanpa pembandingan palsu ini "email tidak ada"
// terjawab jauh lebih cepat daripada "kata sandi salah" - dan selisih waktunya
// cukup untuk menebak email mana yang terdaftar.
const dummyHash = `$2a$10$OnrwE1aqxMka7XbnLQ5HXO5iGJMUMyh7rmL34KXyWCjck4dNCmuwW`

type Handler struct {
	db     *pgxpool.Pool
	signer *Signer
}

func NewHandler(db *pgxpool.Pool, signer *Signer) *Handler {
	return &Handler{db: db, signer: signer}
}

type loginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type userView struct {
	ID       int64  `json:"id"`
	Email    string `json:"email"`
	FullName string `json:"full_name"`
	Role     string `json:"role"`
}

// Login memeriksa email dan kata sandi, lalu menerbitkan JWT.
func (h *Handler) Login(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := httpx.DecodeJSON(r, &req); err != nil {
		httpx.Fail(w, http.StatusBadRequest, "invalid_body", "Badan permintaan bukan JSON yang sah")
		return
	}

	// Email disimpan dengan huruf kecil.
	email := strings.ToLower(strings.TrimSpace(req.Email))
	if email == "" || req.Password == "" {
		httpx.Fail(w, http.StatusBadRequest, "invalid_body", "email dan password wajib diisi")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	var (
		user     userView
		hash     string
		isActive bool
	)
	err := h.db.QueryRow(ctx, `
		SELECT id, email, full_name, role, password_hash, is_active
		  FROM users
		 WHERE email = $1`, email,
	).Scan(&user.ID, &user.Email, &user.FullName, &user.Role, &hash, &isActive)

	switch {
	case errors.Is(err, pgx.ErrNoRows):
		hash = dummyHash
	case err != nil:
		httpx.Internal(w, "login: query pengguna", err)
		return
	}

	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.Password)) != nil || user.ID == 0 {
		httpx.Fail(w, http.StatusUnauthorized, "invalid_credentials", "Email atau kata sandi salah")
		return
	}

	// Diperiksa setelah kata sandi terbukti benar. Pemanggil sudah membuktikan
	// dirinya pemilik akun, jadi tidak ada yang dibocorkan ke orang lain.
	if !isActive {
		httpx.Fail(w, http.StatusForbidden, "account_inactive", "Akun ini sedang tidak aktif")
		return
	}

	token, expiresAt, err := h.signer.Issue(user.ID, user.Role)
	if err != nil {
		httpx.Internal(w, "login: menerbitkan token", err)
		return
	}

	httpx.OK(w, map[string]any{
		"token":      token,
		"token_type": "Bearer",
		"expires_at": expiresAt,
		"user":       user,
	})
}

// Me mengembalikan pemilik token yang sedang dipakai.
func (h *Handler) Me(w http.ResponseWriter, r *http.Request) {
	claims, ok := FromContext(r.Context())
	if !ok {
		httpx.Fail(w, http.StatusUnauthorized, "unauthorized", "Token tidak ditemukan")
		return
	}
	userID, err := claims.UserID()
	if err != nil {
		httpx.Fail(w, http.StatusUnauthorized, "unauthorized", "Isi token tidak sah")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	var user userView
	err = h.db.QueryRow(ctx, `
		SELECT id, email, full_name, role FROM users WHERE id = $1`, userID,
	).Scan(&user.ID, &user.Email, &user.FullName, &user.Role)
	if errors.Is(err, pgx.ErrNoRows) {
		httpx.Fail(w, http.StatusUnauthorized, "unauthorized", "Pengguna pada token sudah tidak ada")
		return
	}
	if err != nil {
		httpx.Internal(w, "me: query pengguna", err)
		return
	}

	httpx.OK(w, user)
}
