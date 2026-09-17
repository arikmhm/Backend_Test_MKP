// Package auth memeriksa kata sandi saat login serta menerbitkan dan
// memeriksa JWT yang dipakai endpoint lain.
package auth

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/arikmhm/Backend_Test_MKP/internal/httpx"
)

// Nilainya sama dengan CHECK pada kolom users.role.
const (
	RoleCustomer = "customer"
	RoleAdmin    = "cinema_admin"
)

// Claims adalah isi token. role dititipkan di dalamnya supaya middleware tidak
// perlu bertanya ke database pada setiap permintaan. Akibatnya, perubahan role
// baru berlaku setelah token lama kedaluwarsa.
type Claims struct {
	Role string `json:"role"`
	jwt.RegisteredClaims
}

func (c *Claims) UserID() (int64, error) {
	return strconv.ParseInt(c.Subject, 10, 64)
}

// Signer menerbitkan dan memeriksa token memakai satu kunci rahasia (HS256).
type Signer struct {
	secret []byte
	ttl    time.Duration
}

// NewSigner menolak kunci pendek saat proses mulai, bukan saat permintaan
// pertama masuk.
func NewSigner(secret string, ttl time.Duration) (*Signer, error) {
	if len(secret) < 32 {
		return nil, errors.New("JWT_SECRET minimal 32 karakter")
	}
	return &Signer{secret: []byte(secret), ttl: ttl}, nil
}

func (s *Signer) Issue(userID int64, role string) (string, time.Time, error) {
	now := time.Now()
	exp := now.Add(s.ttl)

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, Claims{
		Role: role,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   strconv.FormatInt(userID, 10),
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(exp),
		},
	})

	signed, err := token.SignedString(s.secret)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("menandatangani token: %w", err)
	}
	return signed, exp, nil
}

// Parse memeriksa tanda tangan dan masa berlaku token.
//
// WithValidMethods mengunci algoritma ke HS256. Tanpa itu, token bisa datang
// ber-alg "none" tanpa tanda tangan sama sekali dan tetap diterima.
func (s *Signer) Parse(raw string) (*Claims, error) {
	claims := &Claims{}
	_, err := jwt.ParseWithClaims(raw, claims,
		func(*jwt.Token) (any, error) { return s.secret, nil },
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
		jwt.WithExpirationRequired(),
	)
	if err != nil {
		return nil, err
	}
	return claims, nil
}

type ctxKey struct{}

func FromContext(ctx context.Context) (*Claims, bool) {
	c, ok := ctx.Value(ctxKey{}).(*Claims)
	return c, ok
}

// RequireAuth menolak permintaan tanpa header Authorization: Bearer <token>
// yang sah, lalu menitipkan klaim ke context.
func (s *Signer) RequireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, ok := bearer(r.Header.Get("Authorization"))
		if !ok {
			httpx.Fail(w, http.StatusUnauthorized, "unauthorized",
				"Header Authorization: Bearer <token> tidak ada")
			return
		}

		claims, err := s.Parse(raw)
		if err != nil {
			httpx.Fail(w, http.StatusUnauthorized, "unauthorized",
				"Token tidak sah atau sudah kedaluwarsa")
			return
		}

		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, claims)))
	})
}

// RequireAdmin dipasang setelah RequireAuth, untuk endpoint yang mengubah
// jadwal tayang.
func RequireAdmin(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		claims, ok := FromContext(r.Context())
		if !ok || claims.Role != RoleAdmin {
			httpx.Fail(w, http.StatusForbidden, "forbidden",
				"Endpoint ini hanya untuk petugas bioskop")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// bearer memisahkan token dari skemanya. Nama skema tidak peka huruf
// besar-kecil, sesuai RFC 7235.
func bearer(header string) (string, bool) {
	scheme, token, found := strings.Cut(header, " ")
	if !found || !strings.EqualFold(scheme, "Bearer") {
		return "", false
	}
	token = strings.TrimSpace(token)
	return token, token != ""
}
