# Backend Development Test - Mitra Kasih Perkasa 2025

| | |
| --- | --- |
| **Nama** | **Ariyanto Muhammad** |
| Tanggal | 17 September 2026 |
| Email | mhm.ariyanto@gmail.com |
| Phone | 082245750310 |
| Repository | https://github.com/arikmhm/Backend_Test_MKP |

Platform pembelian tiket bioskop online untuk jaringan berskala nasional.

---

## Letak jawaban tiap poin

| Poin soal | Jawaban ada di |
| --- | --- |
| Instruksi 1 - System Design berupa topologi, export JPG | [`docs/diagrams/1-topologi-sistem.jpg`](docs/diagrams/1-topologi-sistem.jpg) |
| A.1 - flowchart yang dapat dipahami orang awam | [`docs/diagrams/2-perjalanan-customer.jpg`](docs/diagrams/2-perjalanan-customer.jpg) |
| A.2 - pemilihan tempat duduk, restok tiket, refund/pembatalan dari bioskop | [`docs/system-design.md`](docs/system-design.md) bagian 3, 4, dan 5 |
| Instruksi 2 - Database Design + script PostgreSQL | [`docs/erd.md`](docs/erd.md) dan [`db/schema.sql`](db/schema.sql) |
| C - API Login User + CRUD jadwal tayang (Golang) | [`cmd/api`](cmd/api) dan [`internal/`](internal) |
| Instruksi 4 - export Postman | [`postman/`](postman) |

## Topologi sistem

![Topologi sistem](docs/diagrams/1-topologi-sistem.jpg)

## Rancangan basis data

![Rancangan basis data](docs/diagrams/5-erd.jpg)

14 tabel. Penjelasan tiap keputusannya ada di [`docs/erd.md`](docs/erd.md), DDL
lengkapnya di [`db/schema.sql`](db/schema.sql).

---

## Cara menjalankan

### Prasyarat

- Go 1.25 atau lebih baru
- PostgreSQL 13 atau lebih baru, dengan extension `btree_gist` tersedia
  (sudah termasuk pada paket `postgresql-contrib` dan pada image Docker resmi)

### 1. Siapkan basis data

```bash
createdb mkp_cinema
psql -d mkp_cinema -f db/schema.sql
psql -d mkp_cinema -f db/seed.sql
```

`seed.sql` mengisi 5 pengguna, 3 bioskop, 6 studio, 672 kursi, 4 film, dan 72
jadwal tayang. Jadwalnya dibuat relatif terhadap tanggal hari ini, jadi datanya
selalu aktual kapan pun diimpor.

### 2. Atur konfigurasi

```bash
cp .env.example .env
```

Sesuaikan `DATABASE_URL`, lalu isi `JWT_SECRET` minimal 32 karakter. Proses
menolak berjalan kalau kuncinya lebih pendek.

```bash
openssl rand -base64 48
```

### 3. Jalankan

```bash
set -a; source .env; set +a; go run ./cmd/api
```

Aplikasi membaca konfigurasi dari environment variable dan tidak memuat `.env`
sendiri, jadi berkasnya perlu di-`source` lebih dulu. Kalau berhasil:

```
api: mendengarkan di http://localhost:8080 (zona waktu Asia/Jakarta, umur token 8h0m0s)
```

### 4. Uji

```bash
go test ./...
```

Selain itu ada dua pemeriksaan lain yang bisa dijalankan:

```bash
psql -d mkp_cinema -f db/verify.sql
```

13 uji perilaku rancangan basis data, dibungkus transaksi dan di-`ROLLBACK`
sehingga tidak meninggalkan data. Isinya antara lain: klaim kursi kedua
mengembalikan 0 baris, pegangan kursi yang kedaluwarsa boleh diambil alih tanpa
ada yang menghapusnya, jadwal bertumpuk di satu studio ditolak, dan satu
pembayaran hanya bisa direfund sekali.

Untuk Postman, impor [`postman/MKP-Cinema-API.postman_collection.json`](postman/MKP-Cinema-API.postman_collection.json)
lalu jalankan lewat Runner dari folder 1 ke folder 3 secara berurutan. Folder 1
menyimpan token ke variabel koleksi, folder berikutnya memakainya. Tidak ada
tanggal atau id yang ditulis mati; semuanya dihitung saat dijalankan atau
diambil dari data seed, jadi koleksi ini bisa dijalankan berulang kali.

---

## Endpoint

| Method | Path | Perlu token | Perlu `cinema_admin` |
| --- | --- | :---: | :---: |
| `POST` | `/api/auth/login` | | |
| `GET` | `/api/auth/me` | ya | |
| `GET` | `/api/showtimes` | ya | |
| `GET` | `/api/showtimes/{id}` | ya | |
| `POST` | `/api/showtimes` | ya | ya |
| `PUT` | `/api/showtimes/{id}` | ya | ya |
| `DELETE` | `/api/showtimes/{id}` | ya | ya |
| `GET` | `/healthz` | | |

`GET /api/showtimes` ikut dikunci token karena soal menyebut CRUD jadwal tayang
memakai Authorization dari poin 1. Pada produk sebenarnya daftar jadwal adalah
katalog publik yang boleh dibaca sebelum masuk akun, seperti dirancang pada
Poin A.

### Akun contoh dari `seed.sql`

| Email | Kata sandi | Role |
| --- | --- | --- |
| `admin@mkp.test` | `admin123` | `cinema_admin` |
| `budi@mail.test` | `password123` | `customer` |

---

## Susunan berkas

```
cmd/api/main.go            konfigurasi, pendaftaran rute, penghentian yang rapi
internal/auth/             penerbitan & pemeriksaan JWT, middleware, login
internal/showtime/         CRUD jadwal tayang, penerjemah galat PostgreSQL
internal/httpx/            pembentuk balasan JSON
db/schema.sql              DDL 14 tabel
db/seed.sql                data contoh
db/verify.sql              13 uji perilaku rancangan
docs/system-design.md      jawaban Poin A
docs/erd.md                jawaban Poin B
docs/diagrams/             5 diagram, masing-masing .jpg dan sumber .drawio
postman/                   koleksi Postman
```

---

## Catatan teknis

**Tanpa framework HTTP.** Routing berpola `"POST /api/showtimes/{id}"` sudah ada
di `net/http` sejak Go 1.22, jadi tidak ada router pihak ketiga di proyek ini.
Dependensinya tiga: `pgx/v5`, `golang-jwt/jwt/v5`, dan `x/crypto` untuk bcrypt.

**Tanpa ORM.** Rancangan basis datanya bertumpu pada hal yang khas PostgreSQL
seperti `EXCLUDE USING gist` dan partial unique index. Galat constraint dari
database dibutuhkan mentah-mentah untuk diterjemahkan menjadi kode HTTP yang
tepat, dan ORM akan menyembunyikannya.

**Aturan ditegakkan database, bukan diperiksa lebih dulu.** Tidak ada `SELECT`
pemeriksaan sebelum menyimpan, baik untuk klaim kursi maupun untuk jadwal yang
bertumpuk. Di antara memeriksa dan menyimpan selalu ada jeda, dan dua permintaan
bisa lolos berdua di jeda itu. Yang dilakukan kode adalah mencoba menyimpan lalu
menerjemahkan penolakannya:

| Kode PostgreSQL | Arti | Jadi |
| --- | --- | --- |
| `23P01` | `EXCLUDE` dilanggar | `409` studio sudah terpakai pada rentang itu |
| `23503` | `RESTRICT` dari `orders`/`tickets` | `409` jadwal sudah dipakai transaksi |
| `23503` | selain itu | `422` film atau studio tidak ditemukan |
| `23514` | `CHECK` dilanggar | `400` |

**`end_time` tidak diminta dari pemanggil.** Dihitung database dari
`movies.duration_minutes` di dalam pernyataan `INSERT` yang sama, sehingga tidak
mungkin melenceng dari durasi filmnya.

**Uang dikirim sebagai teks di JSON** (`"price": "55000.00"`). Angka pecahan JSON
dibaca sebagai float oleh banyak klien, sedangkan kolomnya `NUMERIC(12,2)`.

**`PUT` menolak tiga keadaan**: jadwal yang sudah punya tiket sah, jadwal yang
kursinya sedang dipegang orang (pegangan yang sudah kedaluwarsa tidak dihitung),
dan permintaan yang mengubah `screen_id`. Yang terakhir karena memindahkan jadwal
ke studio lain berarti seluruh denah kursinya berganti, sementara `showtime_seats`
sudah dibuat mengikuti studio yang lama.

**Nama modul.** Pada topologi, bagian yang dikerjakan di Poin C disebut modul
`auth` dan `catalog`. Di dalam kode keduanya menjadi paket `internal/auth` dan
`internal/showtime`.
