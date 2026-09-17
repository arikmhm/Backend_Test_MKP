package auth

import (
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const testSecret = "rahasia-uji-yang-panjangnya-cukup-32"

func newTestSigner(t *testing.T, ttl time.Duration) *Signer {
	t.Helper()
	s, err := NewSigner(testSecret, ttl)
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}
	return s
}

func issue(t *testing.T, s *Signer, userID int64, role string) string {
	t.Helper()
	token, _, err := s.Issue(userID, role)
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	return token
}

func TestNewSignerRejectsShortSecret(t *testing.T) {
	if _, err := NewSigner("pendek", time.Hour); err == nil {
		t.Fatal("kunci pendek seharusnya ditolak")
	}
}

func TestIssueThenParse(t *testing.T) {
	s := newTestSigner(t, time.Hour)

	token, exp, err := s.Issue(42, RoleAdmin)
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	if time.Until(exp) < 59*time.Minute {
		t.Errorf("kedaluwarsa terlalu cepat: %v", exp)
	}

	claims, err := s.Parse(token)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	id, err := claims.UserID()
	if err != nil || id != 42 {
		t.Errorf("UserID() = %d, %v; mau 42", id, err)
	}
	if claims.Role != RoleAdmin {
		t.Errorf("Role = %q; mau %q", claims.Role, RoleAdmin)
	}
}

func TestParseRejects(t *testing.T) {
	s := newTestSigner(t, time.Hour)
	valid := issue(t, s, 1, RoleCustomer)

	otherSigner, err := NewSigner("kunci-lain-yang-juga-cukup-panjang-32", time.Hour)
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}

	// Token ber-alg "none": tanda tangannya dikosongkan.
	b64 := func(s string) string { return base64.RawURLEncoding.EncodeToString([]byte(s)) }
	algNone := b64(`{"alg":"none","typ":"JWT"}`) + "." +
		b64(`{"sub":"1","role":"cinema_admin","exp":99999999999}`) + "."

	cases := []struct {
		name  string
		token string
	}{
		{"tanda tangan diubah", valid[:len(valid)-3] + "aaa"},
		{"ditandatangani kunci lain", issue(t, otherSigner, 1, RoleCustomer)},
		{"alg none", algNone},
		{"sudah kedaluwarsa", issue(t, newTestSigner(t, -time.Minute), 1, RoleCustomer)},
		{"bukan token", "sembarang.teks.saja"},
		{"kosong", ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := s.Parse(tc.token); err == nil {
				t.Error("seharusnya ditolak, tapi diterima")
			}
		})
	}
}

func TestMiddleware(t *testing.T) {
	s := newTestSigner(t, time.Hour)
	adminToken := issue(t, s, 7, RoleAdmin)
	customerToken := issue(t, s, 7, RoleCustomer)

	// Status ini hanya dibalas kalau handler di ujung rantai benar-benar
	// terpanggil, jadi bisa dipakai membedakan "lolos" dari "ditolak".
	reached := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})

	cases := []struct {
		name    string
		handler http.Handler
		header  string
		want    int
	}{
		{"tanpa header", s.RequireAuth(reached), "", http.StatusUnauthorized},
		{"skema salah", s.RequireAuth(reached), "Basic " + customerToken, http.StatusUnauthorized},
		{"bearer huruf kecil", s.RequireAuth(reached), "bearer " + customerToken, http.StatusNoContent},
		{"token sah", s.RequireAuth(reached), "Bearer " + customerToken, http.StatusNoContent},
		{"customer ditolak admin", s.RequireAuth(RequireAdmin(reached)), "Bearer " + customerToken, http.StatusForbidden},
		{"admin lolos", s.RequireAuth(RequireAdmin(reached)), "Bearer " + adminToken, http.StatusNoContent},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/api/showtimes", nil)
			if tc.header != "" {
				req.Header.Set("Authorization", tc.header)
			}
			rec := httptest.NewRecorder()
			tc.handler.ServeHTTP(rec, req)

			if rec.Code != tc.want {
				t.Errorf("status = %d; mau %d (%s)", rec.Code, tc.want,
					strings.TrimSpace(rec.Body.String()))
			}
		})
	}
}
