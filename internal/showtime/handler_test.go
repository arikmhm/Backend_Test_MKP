package showtime

import (
	"encoding/json"
	"net/url"
	"strings"
	"testing"
)

func validRequest() writeRequest {
	return writeRequest{
		MovieID:   1,
		ScreenID:  2,
		StartTime: "2026-10-01T13:00:00+07:00",
		Price:     json.Number("50000"),
	}
}

func TestValidateAccepts(t *testing.T) {
	start, price, err := validRequest().validate()
	if err != nil {
		t.Fatalf("masukan sah ditolak: %v", err)
	}
	if price != "50000" {
		t.Errorf("price = %q; mau \"50000\" apa adanya, tidak lewat float", price)
	}
	if got := start.Format("15:04"); got != "13:00" {
		t.Errorf("jam = %s; mau 13:00", got)
	}
}

func TestValidateRejects(t *testing.T) {
	cases := []struct {
		name  string
		mutat func(*writeRequest)
	}{
		{"movie_id kosong", func(r *writeRequest) { r.MovieID = 0 }},
		{"screen_id negatif", func(r *writeRequest) { r.ScreenID = -1 }},
		{"waktu tanpa zona", func(r *writeRequest) { r.StartTime = "2026-10-01 13:00:00" }},
		{"waktu kosong", func(r *writeRequest) { r.StartTime = "" }},
		{"harga negatif", func(r *writeRequest) { r.Price = json.Number("-1") }},
		{"harga bukan angka", func(r *writeRequest) { r.Price = json.Number("gratis") }},
		{"harga kosong", func(r *writeRequest) { r.Price = "" }},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := validRequest()
			tc.mutat(&req)
			if _, _, err := req.validate(); err == nil {
				t.Error("seharusnya ditolak, tapi diterima")
			}
		})
	}
}

func TestBuildFilter(t *testing.T) {
	cases := []struct {
		name      string
		query     string
		wantWhere string
		wantArgs  int
		wantErr   bool
	}{
		{name: "tanpa penyaring", query: "", wantWhere: "", wantArgs: 0},
		{
			name:      "urutan placeholder tetap",
			query:     "cinema_id=2&movie_id=1",
			wantWhere: "WHERE s.movie_id = $1 AND c.id = $2",
			wantArgs:  2,
		},
		{
			name:      "tanggal jadi rentang sehari",
			query:     "date=2026-09-18",
			wantWhere: "WHERE s.start_time >= $1::date AND s.start_time < $1::date + interval '1 day'",
			wantArgs:  1,
		},
		{name: "movie_id bukan angka", query: "movie_id=abc", wantErr: true},
		{name: "status tidak dikenal", query: "status=entah", wantErr: true},
		{name: "tanggal salah format", query: "date=18-09-2026", wantErr: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			q, err := url.ParseQuery(tc.query)
			if err != nil {
				t.Fatalf("ParseQuery: %v", err)
			}

			clause, args, err := buildFilter(q)
			if tc.wantErr {
				if err == nil {
					t.Fatal("seharusnya ditolak, tapi diterima")
				}
				return
			}
			if err != nil {
				t.Fatalf("buildFilter: %v", err)
			}
			if got := strings.Join(strings.Fields(clause), " "); got != tc.wantWhere {
				t.Errorf("klausa = %q; mau %q", got, tc.wantWhere)
			}
			if len(args) != tc.wantArgs {
				t.Errorf("jumlah argumen = %d; mau %d", len(args), tc.wantArgs)
			}
		})
	}
}

func TestPaging(t *testing.T) {
	cases := []struct {
		query             string
		wantPage, wantPer int
	}{
		{"", 1, 20},
		{"page=3&per_page=50", 3, 50},
		{"page=0", 1, 20},
		{"page=-5&per_page=-1", 1, 20},
		{"per_page=9999", 1, 100},
		{"page=abc&per_page=abc", 1, 20},
	}

	for _, tc := range cases {
		t.Run("?"+tc.query, func(t *testing.T) {
			q, err := url.ParseQuery(tc.query)
			if err != nil {
				t.Fatalf("ParseQuery: %v", err)
			}
			page, perPage := paging(q)
			if page != tc.wantPage || perPage != tc.wantPer {
				t.Errorf("paging = %d, %d; mau %d, %d", page, perPage, tc.wantPage, tc.wantPer)
			}
		})
	}
}
