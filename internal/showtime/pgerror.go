package showtime

import (
	"errors"
	"net/http"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/arikmhm/Backend_Test_MKP/internal/httpx"
)

// handleDBError menerjemahkan penolakan PostgreSQL menjadi jawaban HTTP, dan
// mengembalikan false bila galatnya bukan pelanggaran aturan yang dikenal.
//
// Aturannya sengaja ditegakkan database, bukan dengan SELECT pemeriksaan
// sebelum menyimpan: di antara saat memeriksa dan saat menyimpan ada celah, dan
// dua petugas bisa lolos berdua di celah itu.
func handleDBError(w http.ResponseWriter, err error) bool {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return false
	}

	switch pgErr.Code {
	case "23P01": // exclusion_violation - showtimes_no_overlap
		httpx.Fail(w, http.StatusConflict, "schedule_conflict",
			"Studio sudah terpakai pada rentang waktu tersebut")

	case "23503": // foreign_key_violation
		switch pgErr.ConstraintName {
		case "orders_showtime_id_fkey",
			"tickets_showtime_id_fkey",
			"showtime_cancellations_showtime_id_fkey":
			httpx.Fail(w, http.StatusConflict, "showtime_in_use",
				"Jadwal ini sudah dipakai pesanan atau tiket, jadi tidak bisa dihapus")
		default:
			httpx.Fail(w, http.StatusUnprocessableEntity, "invalid_reference",
				"Film atau studio yang dirujuk tidak ditemukan")
		}

	case "23514": // check_violation
		httpx.Fail(w, http.StatusBadRequest, "invalid_value",
			"Nilai yang dikirim melanggar aturan data: "+pgErr.ConstraintName)

	case "23505": // unique_violation
		httpx.Fail(w, http.StatusConflict, "duplicate",
			"Data serupa sudah ada: "+pgErr.ConstraintName)

	default:
		return false
	}
	return true
}
