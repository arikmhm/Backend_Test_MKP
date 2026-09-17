// Package showtime berisi API CRUD jadwal tayang.
package showtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/arikmhm/Backend_Test_MKP/internal/httpx"
)

type Handler struct {
	db *pgxpool.Pool
}

func New(db *pgxpool.Pool) *Handler {
	return &Handler{db: db}
}

type movieRef struct {
	ID              int64  `json:"id"`
	Title           string `json:"title"`
	DurationMinutes int    `json:"duration_minutes"`
}

type screenRef struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

type cinemaRef struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
	City string `json:"city"`
}

type view struct {
	ID        int64     `json:"id"`
	StartTime time.Time `json:"start_time"`
	EndTime   time.Time `json:"end_time"`
	// Uang dikirim sebagai teks. Angka pecahan JSON dibaca sebagai float oleh
	// banyak klien, sedangkan kolomnya NUMERIC(12,2).
	Price     string    `json:"price"`
	Status    string    `json:"status"`
	Movie     movieRef  `json:"movie"`
	Screen    screenRef `json:"screen"`
	Cinema    cinemaRef `json:"cinema"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// Dipakai bersama oleh list, detail, create, dan update supaya bentuk
// balasan keempatnya sama.
const selectColumns = `
	    s.id, s.start_time, s.end_time, s.price::text, s.status,
	    s.created_at, s.updated_at,
	    m.id, m.title, m.duration_minutes,
	    sc.id, sc.name,
	    c.id, c.name, c.city`

const joinTables = `
	    JOIN movies  m  ON m.id  = s.movie_id
	    JOIN screens sc ON sc.id = s.screen_id
	    JOIN cinemas c  ON c.id  = sc.cinema_id`

func scanView(row pgx.Row) (view, error) {
	var v view
	err := row.Scan(
		&v.ID, &v.StartTime, &v.EndTime, &v.Price, &v.Status,
		&v.CreatedAt, &v.UpdatedAt,
		&v.Movie.ID, &v.Movie.Title, &v.Movie.DurationMinutes,
		&v.Screen.ID, &v.Screen.Name,
		&v.Cinema.ID, &v.Cinema.Name, &v.Cinema.City,
	)
	return v, err
}

// buildFilter menyusun klausa WHERE dari query string.
func buildFilter(q url.Values) (string, []any, error) {
	var (
		where []string
		args  []any
	)
	add := func(clause string, value any) {
		args = append(args, value)
		where = append(where, fmt.Sprintf(clause, len(args)))
	}

	parseID := func(param string) (int64, bool, error) {
		raw := q.Get(param)
		if raw == "" {
			return 0, false, nil
		}
		id, err := strconv.ParseInt(raw, 10, 64)
		if err != nil {
			return 0, false, errors.New(param + " harus berupa angka")
		}
		return id, true, nil
	}

	if id, ok, err := parseID("movie_id"); err != nil {
		return "", nil, err
	} else if ok {
		add("s.movie_id = $%d", id)
	}

	if id, ok, err := parseID("cinema_id"); err != nil {
		return "", nil, err
	} else if ok {
		add("c.id = $%d", id)
	}

	if raw := q.Get("status"); raw != "" {
		if raw != "scheduled" && raw != "cancelled" {
			return "", nil, errors.New("status hanya boleh scheduled atau cancelled")
		}
		add("s.status = $%d", raw)
	}

	// Satu hari penuh menurut zona waktu sesi database, bukan potongan UTC.
	if raw := q.Get("date"); raw != "" {
		if _, err := time.Parse("2006-01-02", raw); err != nil {
			return "", nil, errors.New("date harus berformat YYYY-MM-DD")
		}
		args = append(args, raw)
		where = append(where, fmt.Sprintf(
			"s.start_time >= $%d::date AND s.start_time < $%d::date + interval '1 day'",
			len(args), len(args)))
	}

	if len(where) == 0 {
		return "", args, nil
	}
	return " WHERE " + strings.Join(where, " AND "), args, nil
}

func paging(q url.Values) (page, perPage int) {
	page, _ = strconv.Atoi(q.Get("page"))
	if page < 1 {
		page = 1
	}
	perPage, _ = strconv.Atoi(q.Get("per_page"))
	switch {
	case perPage < 1:
		perPage = 20
	case perPage > 100:
		perPage = 100
	}
	return page, perPage
}

// List menampilkan jadwal tayang.
//
//	GET /api/showtimes?movie_id=&cinema_id=&date=YYYY-MM-DD&status=&page=&per_page=
func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	clause, args, err := buildFilter(r.URL.Query())
	if err != nil {
		httpx.Fail(w, http.StatusBadRequest, "invalid_query", err.Error())
		return
	}
	page, perPage := paging(r.URL.Query())

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	var total int64
	if err := h.db.QueryRow(ctx,
		`SELECT count(*) FROM showtimes s`+joinTables+clause, args...,
	).Scan(&total); err != nil {
		httpx.Internal(w, "showtime list: hitung total", err)
		return
	}

	rows, err := h.db.Query(ctx,
		`SELECT`+selectColumns+` FROM showtimes s`+joinTables+clause+
			fmt.Sprintf(` ORDER BY s.start_time, s.id LIMIT $%d OFFSET $%d`,
				len(args)+1, len(args)+2),
		append(args, perPage, (page-1)*perPage)...)
	if err != nil {
		httpx.Internal(w, "showtime list: query", err)
		return
	}
	defer rows.Close()

	items := make([]view, 0, perPage)
	for rows.Next() {
		v, err := scanView(rows)
		if err != nil {
			httpx.Internal(w, "showtime list: scan", err)
			return
		}
		items = append(items, v)
	}
	if err := rows.Err(); err != nil {
		httpx.Internal(w, "showtime list: baca baris", err)
		return
	}

	httpx.Page(w, items, page, perPage, total)
}

// Detail menampilkan satu jadwal tayang.
//
//	GET /api/showtimes/{id}
func (h *Handler) Detail(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	v, err := scanView(h.db.QueryRow(ctx,
		`SELECT`+selectColumns+` FROM showtimes s`+joinTables+` WHERE s.id = $1`, id))
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		notFound(w)
	case err != nil:
		httpx.Internal(w, "showtime detail: query", err)
	default:
		httpx.OK(w, v)
	}
}

type writeRequest struct {
	MovieID   int64       `json:"movie_id"`
	ScreenID  int64       `json:"screen_id"`
	StartTime string      `json:"start_time"`
	Price     json.Number `json:"price"`
}

// validate memeriksa masukan di batas kepercayaan. Aturan yang sama juga
// dijaga CHECK constraint; yang di sini ada supaya pemanggil mendapat pesan
// yang jelas, bukan nama constraint.
func (req writeRequest) validate() (time.Time, string, error) {
	if req.MovieID <= 0 || req.ScreenID <= 0 {
		return time.Time{}, "", errors.New("movie_id dan screen_id wajib diisi")
	}

	// Zona waktu wajib ikut: "jam 13:00" tidak punya arti tunggal bagi
	// jaringan bioskop lintas zona.
	start, err := time.Parse(time.RFC3339, req.StartTime)
	if err != nil {
		return time.Time{}, "", errors.New("start_time harus berformat RFC3339 lengkap dengan zona waktu, misal 2026-10-01T13:00:00+07:00")
	}

	price := req.Price.String()
	if price == "" {
		return time.Time{}, "", errors.New("price wajib diisi")
	}
	amount, err := strconv.ParseFloat(price, 64)
	if err != nil || amount < 0 {
		return time.Time{}, "", errors.New("price harus berupa angka tidak negatif")
	}

	return start, price, nil
}

// Create menyimpan jadwal baru. end_time tidak diminta dari pemanggil
// melainkan dihitung database dari durasi film di dalam pernyataan yang sama,
// sehingga tidak mungkin melenceng dari durasinya.
//
//	POST /api/showtimes
func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	var req writeRequest
	if err := httpx.DecodeJSON(r, &req); err != nil {
		httpx.Fail(w, http.StatusBadRequest, "invalid_body", "Badan permintaan bukan JSON yang sah")
		return
	}
	start, price, err := req.validate()
	if err != nil {
		httpx.Fail(w, http.StatusBadRequest, "invalid_body", err.Error())
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	v, err := scanView(h.db.QueryRow(ctx, `
	    WITH baru AS (
	        INSERT INTO showtimes (movie_id, screen_id, start_time, end_time, price)
	        SELECT m.id, $2, $3, $3::timestamptz + make_interval(mins => m.duration_minutes), $4::numeric
	          FROM movies m
	         WHERE m.id = $1 AND m.is_active
	        RETURNING *
	    )
	    SELECT`+selectColumns+`
	      FROM baru s`+joinTables,
		req.MovieID, req.ScreenID, start, price))

	switch {
	case errors.Is(err, pgx.ErrNoRows):
		// Satu-satunya sumber baris adalah tabel movies.
		httpx.Fail(w, http.StatusUnprocessableEntity, "movie_not_found",
			"Film tidak ditemukan atau sudah tidak aktif")
	case err != nil:
		if !handleDBError(w, err) {
			httpx.Internal(w, "showtime create: query", err)
		}
	default:
		httpx.Created(w, v)
	}
}

// Update mengubah jadwal yang belum tersentuh pembeli. Ada tiga hal yang
// sengaja ditolak, dan semuanya karena alasan yang sama - di ujung sana ada
// orang yang sudah bertindak berdasarkan jadwal ini:
//
//   - sudah ada tiket sah
//
//   - ada kursi terjual, atau kursi yang pegangannya masih hidup (seseorang
//     sedang di tengah pembayaran; pegangan yang sudah kedaluwarsa tidak
//     dihitung, sesuai cara kerja penahanan kursi)
//
//   - screen_id diubah; memindahkan jadwal ke studio lain berarti seluruh
//     denah kursinya berganti, dan itu jadwal baru, bukan suntingan
//
//     PUT /api/showtimes/{id}
func (h *Handler) Update(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}

	var req writeRequest
	if err := httpx.DecodeJSON(r, &req); err != nil {
		httpx.Fail(w, http.StatusBadRequest, "invalid_body", "Badan permintaan bukan JSON yang sah")
		return
	}
	start, price, err := req.validate()
	if err != nil {
		httpx.Fail(w, http.StatusBadRequest, "invalid_body", err.Error())
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	v, err := scanView(h.db.QueryRow(ctx, `
	    WITH ubah AS (
	        UPDATE showtimes s
	           SET movie_id   = m.id,
	               start_time = $4,
	               end_time   = $4::timestamptz + make_interval(mins => m.duration_minutes),
	               price      = $5::numeric
	          FROM movies m
	         WHERE s.id = $1
	           AND s.status = 'scheduled'
	           AND s.screen_id = $3
	           AND m.id = $2
	           AND m.is_active
	           AND NOT EXISTS (
	               SELECT 1 FROM tickets t
	                WHERE t.showtime_id = s.id AND t.status = 'valid'
	           )
	           AND NOT EXISTS (
	               SELECT 1 FROM showtime_seats ss
	                WHERE ss.showtime_id = s.id
	                  AND (ss.status = 'sold'
	                    OR (ss.status = 'held' AND ss.expires_at > now()))
	           )
	        RETURNING s.*
	    )
	    SELECT`+selectColumns+`
	      FROM ubah s`+joinTables,
		id, req.MovieID, req.ScreenID, start, price))

	switch {
	case errors.Is(err, pgx.ErrNoRows):
		h.explainWriteRejection(ctx, w, id, req.MovieID, req.ScreenID)
	case err != nil:
		if !handleDBError(w, err) {
			httpx.Internal(w, "showtime update: query", err)
		}
	default:
		httpx.OK(w, v)
	}
}

// explainWriteRejection dijalankan hanya ketika UPDATE mengubah nol baris,
// untuk menerangkan syarat mana yang tidak terpenuhi. Satu query tambahan, dan
// hanya pada jalur penolakan.
func (h *Handler) explainWriteRejection(ctx context.Context, w http.ResponseWriter, id, movieID, screenID int64) {
	var (
		exists, cancelled, hasTickets, seatsTaken, movieOK bool
		currentScreen                                      int64
	)
	err := h.db.QueryRow(ctx, `
	    SELECT EXISTS (SELECT 1 FROM showtimes WHERE id = $1),
	           EXISTS (SELECT 1 FROM showtimes WHERE id = $1 AND status = 'cancelled'),
	           EXISTS (SELECT 1 FROM tickets WHERE showtime_id = $1 AND status = 'valid'),
	           EXISTS (SELECT 1 FROM showtime_seats
	                    WHERE showtime_id = $1
	                      AND (status = 'sold'
	                        OR (status = 'held' AND expires_at > now()))),
	           EXISTS (SELECT 1 FROM movies WHERE id = $2 AND is_active),
	           coalesce((SELECT screen_id FROM showtimes WHERE id = $1), 0)`,
		id, movieID,
	).Scan(&exists, &cancelled, &hasTickets, &seatsTaken, &movieOK, &currentScreen)
	if err != nil {
		httpx.Internal(w, "showtime update: alasan penolakan", err)
		return
	}

	switch {
	case !exists:
		notFound(w)
	case hasTickets:
		httpx.Fail(w, http.StatusConflict, "showtime_has_tickets",
			"Jadwal ini sudah memiliki tiket terjual, jadi tidak bisa diubah. "+
				"Perubahan jadwal yang sudah terjual harus lewat pembatalan dan pengembalian dana.")
	case seatsTaken:
		httpx.Fail(w, http.StatusConflict, "showtime_seats_taken",
			"Ada kursi pada jadwal ini yang sedang dipegang atau sudah terjual. "+
				"Coba lagi setelah pegangan kursi itu kedaluwarsa.")
	case cancelled:
		httpx.Fail(w, http.StatusConflict, "showtime_cancelled",
			"Jadwal ini sudah dibatalkan, jadi tidak bisa diubah")
	case currentScreen != screenID:
		httpx.Fail(w, http.StatusConflict, "screen_not_changeable",
			fmt.Sprintf("Jadwal ini berada di studio %d dan tidak bisa dipindahkan lewat endpoint ini, "+
				"karena seluruh denah kursinya akan berganti. Hapus jadwal ini lalu buat yang baru.",
				currentScreen))
	case !movieOK:
		httpx.Fail(w, http.StatusUnprocessableEntity, "movie_not_found",
			"Film tidak ditemukan atau sudah tidak aktif")
	default:
		httpx.Fail(w, http.StatusConflict, "update_rejected", "Jadwal tidak dapat diubah")
	}
}

// Delete menghapus jadwal. Perilakunya ditentukan schema, bukan kode di sini:
// showtime_seats ikut terhapus (CASCADE), sedangkan orders, tickets, dan
// showtime_cancellations menahan penghapusan (RESTRICT).
//
//	DELETE /api/showtimes/{id}
func (h *Handler) Delete(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	tag, err := h.db.Exec(ctx, `DELETE FROM showtimes WHERE id = $1`, id)
	if err != nil {
		if !handleDBError(w, err) {
			httpx.Internal(w, "showtime delete: query", err)
		}
		return
	}
	if tag.RowsAffected() == 0 {
		notFound(w)
		return
	}

	httpx.OK(w, map[string]any{"id": id, "deleted": true})
}

func pathID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		httpx.Fail(w, http.StatusBadRequest, "invalid_id", "id pada alamat harus berupa angka positif")
		return 0, false
	}
	return id, true
}

func notFound(w http.ResponseWriter) {
	httpx.Fail(w, http.StatusNotFound, "not_found", "Jadwal tayang tidak ditemukan")
}
