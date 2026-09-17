# Database Design - Poin B

Rancangan basis data untuk platform pembelian tiket bioskop online. Tiap tabel
di sini bisa saya tunjuk asalnya dari keputusan di Poin A.

![Rancangan basis data](diagrams/5-erd.jpg)

Sumber: [`5-erd.drawio`](diagrams/5-erd.drawio) · DDL lengkapnya di
[`../db/schema.sql`](../db/schema.sql)

14 tabel. Warnanya mengikuti peran: hijau untuk akun, biru untuk katalog yang
boleh dibaca sebelum masuk akun, oranye untuk inti penguncian kursi, ungu untuk
transaksi uang, kuning untuk pencatatan, abu untuk infrastruktur.

## Bentuk query yang paling sering dipakai

Saat mencoba beberapa aplikasi tiket, alurnya selalu sama: pilih kota, pilih
film, lalu muncul daftar bioskop beserta jam tayang dan harganya. Jadi
pertanyaan terbesar ke database ini:

> "Untuk kota X dan film Y pada tanggal Z, ada jadwal apa saja, di bioskop mana,
> jam berapa, harganya berapa?"

Jalurnya lewat tiga tabel:

```
cinemas (city) ──< screens ──< showtimes >── movies
```

Dari situ ada dua hal yang saya putuskan. Harga saya taruh di `showtimes`, bukan
dihitung belakangan, karena harganya sudah tampil di daftar jadwal sebelum user
memilih kursi. Dan kolom `city` tetap di `cinemas`, penyaringan kotanya lewat
join. Menyalin `city` ke `showtimes` memang akan mempercepat sedikit, tapi belum
ada alasan yang menuntutnya, dan salinan berarti ada dua tempat yang bisa
berbeda isi.

## Beberapa keputusan yang perlu saya jelaskan

**`showtime_seats`.** `PRIMARY KEY (showtime_id, seat_id)` bikin satu kursi pada
satu jadwal hanya punya satu baris, dan itu inti dari jawaban Poin A.
`held_by_order` menunjuk ke `orders.id`, itu sebabnya pesanan harus dibuat lebih
dulu. `expires_at` tidak dibersihkan siapa pun; baris yang kedaluwarsa hanya
boleh diambil alih.

**`tickets`.** Satu tiket = satu kursi = satu kode QR yang discan di pintu. Di
sini saya sempat salah: kalau dipasang `UNIQUE (showtime_id, seat_id)` biasa,
tiket untuk kursi yang sudah direfund lalu dijual ulang akan ditolak, padahal itu
kejadian yang sah. Jadi yang dipakai partial unique index:

```sql
CREATE UNIQUE INDEX ON tickets (showtime_id, seat_id) WHERE status = 'valid';
```

Versi ini diterima karena syaratnya bersandar pada kolom biasa. Saya sempat
mencoba `WHERE expires_at > now()` dan ditolak PostgreSQL; yang ditolak bukan
partial index-nya, tapi `now()`, karena nilainya berubah tiap detik sementara isi
index ditulis sekali lalu disimpan.

**Dua penjaga idempotency.** `payments.payment_reference` UNIQUE menjaga
notifikasi pembayaran yang datang dua kali, dan `refunds.payment_id` UNIQUE
menjaga satu pembayaran supaya hanya bisa direfund sekali. Beda urusan, jadi
tidak bisa digabung.

**`seat_inventory_ledger`.** Tidak ada `UPDATE` maupun `DELETE` di tabel ini.
Status terkini tetap di `showtime_seats` supaya denah kursi cepat dibaca, dan
tabel ini menyimpan sejarahnya. Keduanya ditulis dalam satu transaksi.

**`jobs`.** Sengaja tanpa relasi ke tabel mana pun. Isinya JSON dan sasarannya
dirujuk lewat `payload`, jadi satu antrean bisa melayani beberapa jenis
pekerjaan. Kalau dipasang foreign key, antreannya terkunci pada satu jenis saja.

**Satu tabel `users` untuk dua peran.** Kolom `role` membedakan `customer` dan
`cinema_admin`, dan keduanya masuk lewat endpoint login yang sama, yang saya
implementasikan di Poin C.

## Yang diuji

`db/verify.sql` berisi 13 uji perilaku rancangan ini, dibungkus transaksi dan
di-`ROLLBACK` sehingga tidak meninggalkan data. Antara lain: klaim kursi kedua
mengembalikan 0 baris, pegangan kursi yang kedaluwarsa boleh diambil alih tanpa
ada yang menghapusnya, jadwal bertumpuk di satu studio ditolak, kursi yang sudah
direfund boleh dijual ulang, dan satu pembayaran hanya bisa direfund sekali.
