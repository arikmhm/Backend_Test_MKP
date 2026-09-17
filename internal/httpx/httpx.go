// Package httpx membentuk balasan JSON supaya seragam di semua endpoint.
package httpx

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
)

type errorBody struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func write(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(body); err != nil {
		log.Printf("httpx: gagal menulis balasan: %v", err)
	}
}

func OK(w http.ResponseWriter, data any) {
	write(w, http.StatusOK, map[string]any{"data": data})
}

func Created(w http.ResponseWriter, data any) {
	write(w, http.StatusCreated, map[string]any{"data": data})
}

func Page(w http.ResponseWriter, data any, page, perPage int, total int64) {
	write(w, http.StatusOK, map[string]any{
		"data": data,
		"meta": map[string]any{"page": page, "per_page": perPage, "total": total},
	})
}

// Fail membalas galat: code untuk dibaca mesin, message untuk dibaca manusia.
func Fail(w http.ResponseWriter, status int, code, message string) {
	write(w, status, map[string]any{"error": errorBody{Code: code, Message: message}})
}

// Internal mencatat penyebab sebenarnya ke log dan membalas pesan umum.
func Internal(w http.ResponseWriter, context string, err error) {
	log.Printf("%s: %v", context, err)
	Fail(w, http.StatusInternalServerError, "internal_error", "Terjadi kesalahan pada server")
}

// DecodeJSON menolak kolom yang tidak dikenal, supaya salah tulis nama kolom
// tidak diam-diam terabaikan.
func DecodeJSON(r *http.Request, dst any) error {
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	dec.DisallowUnknownFields()
	return dec.Decode(dst)
}
