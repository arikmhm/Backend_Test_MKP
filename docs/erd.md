# Database Design - Poin B

Rancangan basis data untuk platform pembelian tiket bioskop online.
Setiap tabel di sini bisa ditunjuk asalnya dari keputusan pada Poin A.

## 1. ERD

![Rancangan basis data](diagrams/5-erd.jpg)

Sumber: [`5-erd.drawio`](diagrams/5-erd.drawio) · DDL lengkapnya di
[`../db/schema.sql`](../db/schema.sql)

14 tabel. Warna mengikuti peran: hijau untuk akun, biru untuk katalog yang boleh
dibaca sebelum masuk akun, oranye untuk inti penguncian kursi, ungu untuk
transaksi uang, kuning untuk pencatatan, dan abu untuk infrastruktur.

`jobs` sengaja tidak punya relasi ke tabel mana pun: isinya JSON, dan
pekerjaannya dirujuk lewat `payload`. Memaksakan foreign key ke sana justru
mengunci antrean pada satu jenis pekerjaan saja.

---

## 2. Alur tampilan dan bentuk datanya

Alur nyata pada aplikasi tiket: pilih kota, pilih film, lalu muncul daftar
bioskop beserta jam tayang dan harganya.

Artinya pertanyaan terbesar ke database adalah:

> "Untuk kota X dan film Y pada tanggal Z, ada jadwal apa saja, di bioskop mana,
> jam berapa, harganya berapa?"

Jalurnya melewati tiga tabel:

```
cinemas (city) ──< screens ──< showtimes >── movies
```

Dua hal yang mengikuti dari situ:

1. Harga berada di `showtimes`, bukan dihitung belakangan, karena harga
   sudah tampil di daftar jadwal, sebelum user memilih kursi. Satu harga per
   jadwal sudah cukup untuk layar itu.
2. Kolom `city` ada di `cinemas`, dan penyaringan kota dilakukan lewat join.
   Menyalin `city` ke `showtimes` (denormalisasi) akan mempercepat sedikit, tapi
   belum ada alasan yang menuntutnya, dan salinan berarti ada dua tempat yang
   bisa berbeda isi.

Index yang mendukung layar itu dibahas bersama `schema.sql`.

---

## 3. Catatan rancangan

### 3.1 `showtime_seats`, inti dari Poin A

`PRIMARY KEY (showtime_id, seat_id)` membuat satu kursi pada satu jadwal hanya
punya satu baris. Pemilik kedua tidak ditolak karena ada yang memeriksa, tapi
karena tidak ada tempat untuknya.

`held_by_order` menunjuk ke `orders.id`, itu sebabnya pesanan harus dibuat lebih
dulu. Dan `expires_at` tidak dibersihkan siapa pun; baris yang kedaluwarsa hanya
boleh diambil alih.

### 3.2 `tickets`, satu baris per kursi dengan penjaga kedua

Satu tiket = satu kursi = satu kode QR yang discan di pintu.

Di sini ada satu hal yang perlu ketelitian. Kalau dipasang
`UNIQUE (showtime_id, seat_id)` biasa, tiket untuk kursi yang sudah direfund lalu
dijual ulang akan ditolak, padahal itu kejadian yang sah.

Yang dipakai adalah partial unique index:

```sql
CREATE UNIQUE INDEX ON tickets (showtime_id, seat_id) WHERE status = 'valid';
```

Boleh, karena syaratnya bersandar pada kolom biasa. Bandingkan dengan yang tidak
boleh dan sempat saya coba pada rancangan awal:

```sql
CREATE UNIQUE INDEX ... WHERE expires_at > now();   -- ditolak PostgreSQL
```

Yang ditolak bukan partial index-nya melainkan `now()`: nilainya berubah tiap
detik, sementara isi index ditulis sekali lalu disimpan.

### 3.3 Dua penjaga idempotency

| Kolom | Menjaga |
| ----- | ------- |
| `payments.payment_reference` UNIQUE | Notifikasi pembayaran yang datang dua kali |
| `refunds.payment_id` UNIQUE | Satu pembayaran hanya bisa direfund satu kali |

Keduanya beda urusan, jadi tidak bisa digabung.

### 3.4 `seat_inventory_ledger` hanya ditambah

Tidak ada `UPDATE` maupun `DELETE` pada tabel ini. Status terkini tetap disimpan
di `showtime_seats` supaya denah kursi cepat dibaca; tabel ini menyimpan
sejarahnya, dan keduanya ditulis dalam satu transaksi.

### 3.5 Satu tabel `users` untuk dua peran

Kolom `role` membedakan `customer` dan `cinema_admin`. Keduanya masuk lewat
endpoint login yang sama, yang diimplementasikan pada Poin C.
