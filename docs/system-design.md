# System Design - Platform Pembelian Tiket Bioskop Online

Backend Development Test, Mitra Kasih Perkasa 2025 - Poin A

Soal meminta tiga hal dijelaskan: sistem pemilihan tempat duduk yang tetap benar
walau diakses banyak orang, sistem restok tiket yang sudah terjual, dan alur
refund atau pembatalan dari pihak bioskop. Ketiganya dijawab pada bagian 3, 4,
dan 5. Diagram pendukungnya ditanam langsung di bagian yang membahasnya.

---

## 1. Masalah inti

Kalimat kunci dari soal:

> "customer dapat melakukan transaksi kapanpun secara online tanpa khawatir
> mengenai nomor kursi tempat duduk karena tidak akan digunakan oleh orang lain"

Saya membacanya sebagai satu masalah spesifik: ada jeda waktu antara "saya pilih
kursi" dan "uang benar-benar masuk". User memilih kursi, memilih metode
pembayaran, membuka aplikasi bank, membayar, lalu notifikasinya sampai ke
sistem. Jeda itu bisa beberapa menit.

Selama jeda itu, kursi A5 milik siapa? Kalau belum milik siapa-siapa sampai
lunas, dua orang bisa membayar untuk kursi yang sama. Kalau langsung miliknya
selamanya begitu diklik, satu orang bisa memblokir seluruh studio tanpa pernah
membayar.

Jadi kursi dipegang sementara dengan batas waktu **7 menit**: cukup panjang untuk
menyelesaikan pembayaran di aplikasi bank, cukup pendek supaya kursi tidak
tertahan lama oleh orang yang tidak jadi membeli. Angka itu saya taruh di
konfigurasi, bukan dipaku di kode, karena nilai yang tepat hanya bisa ditentukan
dari data pembayaran yang sebenarnya. Semua tenggat lain dalam rancangan ini
mengikuti nilai tersebut.

---

## 2. Alur yang dilihat customer

Tugas A.1 meminta flowchart yang dapat dipahami orang awam:

![Perjalanan customer membeli tiket](diagrams/2-perjalanan-customer.jpg)

Sumber: [`2-perjalanan-customer.drawio`](diagrams/2-perjalanan-customer.drawio)

Di belakang alur itu, seluruh rancangan berputar pada satu siklus hidup kursi,
dan siklus itulah yang menjawab ketiga pertanyaan pada Tugas A.2:

```
available ──► held (sementara) ──► sold ──► refunded
    ▲              │                            │
    └──────────────┴────────────────────────────┘
        kembali tersedia (restok)
```

- Pemilihan kursi = perpindahan `available → held → sold`, harus aman saat banyak
  orang berebut (bagian 3).
- Pencatatan dan restok = perpindahan balik ke `available`, beserta riwayatnya
  (bagian 4).
- Refund dan pembatalan = perpindahan `sold → refunded`, beserta urusan uang
  (bagian 5).

---

## 3. Sistem pemilihan kursi

### 3.1 Cara yang umum dipakai justru tidak aman

Pendekatan yang paling sering ditemui:

```
1. cek ke database: apakah kursi A5 masih kosong?
2. kalau kosong → simpan kursi A5 atas nama user ini
```

Di antara langkah 1 dan 2 ada jeda, dan dua permintaan yang datang hampir
bersamaan bisa sama-sama lolos pengecekan sebelum salah satunya menyimpan:

```
10:00.000   Budi  : cek A5 → kosong
10:00.001   Siti  : cek A5 → kosong     (Budi belum sempat menyimpan)
10:00.002   Budi  : simpan A5
10:00.003   Siti  : simpan A5
```

Celah ini tidak bisa ditutup dengan mengecek lebih teliti, karena jedanya selalu
ada. Prinsip yang saya pegang:

> Kalau kebenaran data bergantung pada `if` di kode aplikasi, ada celah. Kalau
> bergantung pada aturan yang ditegakkan mesin database, tidak ada.

### 3.2 Satu kursi pada satu jadwal = satu baris

```sql
CREATE TABLE showtime_seats (
  showtime_id   BIGINT      NOT NULL REFERENCES showtimes(id),
  seat_id       BIGINT      NOT NULL REFERENCES seats(id),
  status        TEXT        NOT NULL DEFAULT 'available',  -- available | held | sold
  held_by_order BIGINT,
  expires_at    TIMESTAMPTZ,
  PRIMARY KEY (showtime_id, seat_id)
);
```

Barisnya dibuat otomatis saat jadwal dibuat. `PRIMARY KEY (showtime_id, seat_id)`
membuat satu kursi hanya punya satu baris, jadi pemilik kedua tidak ditolak
karena ada yang memeriksa, tapi karena tidak ada tempat untuknya.

### 3.3 Klaim kursi = satu perintah bersyarat

```sql
UPDATE showtime_seats
SET    status = 'held', held_by_order = $3,
       expires_at = now() + interval '7 minutes'
WHERE  showtime_id = $1 AND seat_id = $2
  AND  (status = 'available'
        OR (status = 'held' AND expires_at <= now()))   -- pegangan lama sudah mati
RETURNING seat_id;
```

Memeriksa dan mengubah terjadi dalam satu operasi, jadi tidak ada jeda yang bisa
disela. Satu baris kembali berarti kursi sah dipegang pesanan ini. Nol baris
kembali berarti kursi sedang dipegang orang lain atau sudah terjual, dan
permintaannya ditolak dengan pesan "kursi baru saja diambil pengguna lain".

Soal meminta rancangan ini tetap bisa diakses banyak orang. PostgreSQL mengunci
baris kursi itu saja selama `UPDATE` berjalan, sehingga dua permintaan untuk
kursi yang sama dievaluasi berurutan sementara kursi lain di studio yang sama
tidak terpengaruh. Antrean hanya terjadi di antara orang yang memang berebut
kursi yang sama persis.

Saya memilih menolak yang kalah, bukan mengunci lebih awal lalu membuat orang
menunggu. Bentrokan per kursi sebenarnya jarang; yang ramai adalah jadwal
tayangnya. Dan kalau memang bentrok, "kursi sudah diambil" itu jawaban yang
benar, karena menunggu tidak mengubah hasilnya.

### 3.4 Status pesanan, dan kasus tagihan gagal terbit

![Alur teknis pemesanan kursi](diagrams/3-alur-teknis-pemesanan.jpg)

Sumber: [`3-alur-teknis-pemesanan.drawio`](diagrams/3-alur-teknis-pemesanan.drawio)

Pembelian melewati dua halaman dan dua panggilan API, bukan satu:

```
[daftar film, bioskop, jam tayang]    ← data publik, bisa di-cache
     │  ┌── GERBANG: harus masuk akun
     ▼  ▼
[halaman denah kursi]
     │ tekan "Lanjutkan"
     ▼  POST /orders                  → pesanan PENDING + kursi dipegang,
     │                                  hitung mundur MULAI
[halaman ringkasan pesanan]           ← user memilih metode pembayaran
     │ tekan "Bayar"
     ▼  POST /orders/{id}/payment     → minta tagihan ke payment gateway
[halaman instruksi pembayaran]        ← Virtual Account / QR + hitung mundur
```

Gerbang akun saya letakkan sebelum denah kursi. Kalau akun baru diminta setelah
kursi dipilih, user sudah mengerjakan sesuatu lalu disuruh mendaftar, dan
pendaftaran bisa memakan beberapa menit karena verifikasi email atau OTP. Saat
ia kembali, kursi pilihannya bisa sudah diambil orang lain. Letak itu juga jatuh
di batas antara data publik (kota, film, jam tayang) dan data rebutan (denah
kursi), sehingga pembatasan kuota per akun menjadi mungkin. Konsekuensinya
daftar jam tayang tidak memuat indikator ketersediaan kursi.

Kursi dipegang pada panggilan pertama, saat user meninggalkan halaman denah
kursi. Kalau kursi baru dipegang pada panggilan kedua, dua orang bisa duduk di
halaman ringkasan untuk kursi yang sama, dan yang kalah baru ditolak setelah
memilih metode pembayaran.

Pesanannya dibuat lebih dulu karena `held_by_order` menunjuk ke `orders.id`:
pemegang kursi harus punya identitas, dan identitas itu adalah pesanannya.

| Status | Artinya | User bisa membayar? |
| ------ | ------- | ------------------- |
| `PENDING` | Pesanan dibuat, kursi sudah dipegang, tagihan belum terbit | Belum |
| `AWAITING_PAYMENT` | Tagihan terbit (Virtual Account / QR sudah ada) | Ya |
| `PAID` | Pembayaran terkonfirmasi, tiket terbit | - |
| `FAILED` | Tenggat terlewat, atau pembayaran ditolak | - |
| `CANCELLED` | Dibatalkan user atau pihak bioskop | - |
| `REFUNDED` | Dana sudah dikembalikan | - |

`PENDING` bukan status sekejap. Ia dihuni selama user memilih metode pembayaran,
bisa satu sampai dua menit, dan panggilan ke payment gateway sendiri juga bisa
gagal. Kalau tagihan gagal terbit dan percobaan ulang tetap gagal, pesanan
dibatalkan dan kursi dilepas saat itu juga, tidak menunggu 7 menit habis.

### 3.5 Membeli beberapa kursi sekaligus

Orang menonton berdua atau bertiga, jadi klaim beberapa kursi harus
semua-atau-tidak. Kalau A6 keburu diambil, A5 dan A7 tidak boleh tetap tertahan.
Ketiganya dijalankan dalam satu transaksi: kalau jumlah baris yang berubah lebih
sedikit dari jumlah kursi yang diminta, seluruh transaksi di-`ROLLBACK`.

Satu hal yang perlu diperhatikan di sini: kalau Budi memilih [A5, A6] dan Siti
memilih [A6, A5] pada saat yang sama, keduanya bisa saling menunggu kunci yang
dipegang lawannya. Pencegahannya kursi selalu dikunci dalam urutan yang sama,
nomor terkecil lebih dulu, lewat sub-query `ORDER BY seat_id ... FOR UPDATE`.

### 3.6 Peran Redis, dan kalau Redis mati

Beban terbesar sistem ini bukan pembelian melainkan pembacaan denah kursi: satu
orang membuka denah berkali-kali sebelum memutuskan, dan satu jadwal populer
bisa dibuka ratusan orang sekaligus. Karena itu denah kursi dilayani dari Redis,
dan hanya itu peran Redis di sini.

Redis sengaja tidak ikut menahan kursi. Sekali penahanan dipegang oleh perintah
bersyarat di bagian 3.3, kunci tambahan tidak menambah keamanan apa pun tapi
menambah satu cara gagal: kalau proses mati setelah memasang kunci dan sebelum
menulis ke database, kunci itu menggantung untuk kursi yang sebenarnya tidak
pernah dipegang siapa pun. Jadi pembagiannya, Redis melayani pembacaan dan
PostgreSQL memutuskan kepemilikan.

Kalau Redis mati total, pembacaan jatuh ke PostgreSQL sehingga sistem lebih
lambat, tapi tidak pernah menjual kursi yang sama dua kali. Satu jebakan yang
saya tangani: setelah kursi terjual, cache denah dibangun ulang dari PostgreSQL,
bukan sekadar menghapus kunci penahannya, karena "tidak ada yang memegang kursi"
tidak sama dengan "kursi tersedia".

---

## 4. Pencatatan dan restok tiket

### 4.1 Restok terjadi sendiri, tanpa program pembersih

Kursi kembali tersedia pada empat kejadian:

| Kejadian | Pemicu |
| -------- | ------ |
| Masa tahan habis tanpa pembayaran | waktu |
| Pembayaran gagal atau ditolak | webhook dari payment gateway |
| Dibatalkan user sebelum tayang | user (dijual ulang bila masih lebih dari 30 menit sebelum jam tayang) |
| Jadwal dibatalkan pihak bioskop | admin (tidak dijual ulang, jadwalnya mati) |

Untuk kejadian pertama saya tidak menggantungkan restok pada cron job. Kalau
cron mati sepuluh menit, bioskop berhenti menjual kursi yang seharusnya sudah
bebas, dan tidak ada yang menyadarinya.

Yang saya pakai: kursi menyimpan waktu kedaluwarsanya, dan pegangan yang sudah
lewat waktu otomatis boleh diambil alih, lewat klausa `expires_at <= now()` pada
perintah klaim di bagian 3.3. Restok jadi bagian dari proses klaim itu sendiri,
bukan pekerjaan terpisah yang bisa gagal diam-diam. Program pembersih tetap ada
untuk merapikan data dan mengirim metrik, tapi kalau ia mati, sistem tetap benar.

### 4.2 Riwayat tidak boleh tertimpa

Menyimpan hanya status terkini tidak cukup. Kalau kolom `status` ditimpa terus,
maka saat ada keluhan "saya sudah bayar tapi kursi saya diambil orang", yang
terlihat di database hanya satu kata, tanpa keterangan jam berapa berubah, karena
apa, dan oleh siapa.

Karena itu setiap perpindahan keadaan kursi juga dicatat di tabel yang hanya
boleh ditambah:

```
seat_inventory_ledger
| waktu    | showtime | seat | dari      | ke        | sebab           | ref       |
|----------|----------|------|-----------|-----------|-----------------|-----------|
| 19:12:40 | 101      | A5   | HELD      | SOLD      | payment_settled | pay#5521  |
| 20:30:00 | 101      | A5   | SOLD      | REFUNDED  | cinema_cancel   | refund#77 |
```

Prinsipnya seperti buku kas: kesalahan tidak dihapus, tapi dikoreksi dengan baris
baru. Gunanya tiga hal. Sengketa bisa dibuktikan karena ada jejak waktu dan
sebabnya. Laporan penjualan per cabang per periode tinggal diambil, termasuk
persentase pegangan yang hangus, yang kalau tinggi berarti alur pembayarannya
bermasalah. Dan jumlah perpindahan ke `SOLD` bisa dicocokkan dengan uang yang
masuk, sehingga selisih ketahuan di transaksi mana.

Kolom `status` tetap ada sebagai keadaan terkini supaya denah kursi cepat dibaca;
tabel riwayat adalah sejarahnya, dan keduanya ditulis dalam satu transaksi.

---

## 5. Refund dan pembatalan dari pihak bioskop

![Alur refund dan pembatalan](diagrams/4-alur-refund.jpg)

Sumber: [`4-alur-refund.drawio`](diagrams/4-alur-refund.drawio)

Soal menyebut pembatalan dari pihak bioskop, misalnya proyektor rusak atau film
ditarik distributor. Ini berbeda jauh dari pembatalan oleh user:

| | Dibatalkan user | Dibatalkan bioskop |
| --- | --- | --- |
| Pihak yang keliru | User | Bioskop |
| Nilai pengembalian | Sesuai kebijakan potongan | 100%, termasuk biaya layanan |
| Cakupan | 1 pesanan | Seluruh pemesanan pada jadwal itu (bisa ±200) |
| Nasib kursi | Dijual ulang | Tidak, jadwalnya sendiri mati |

### 5.1 Pembatalan adalah operasi massal

Kalau 200 refund dikerjakan langsung di dalam permintaan admin, permintaan itu
akan kehabisan waktu di tengah jalan dan tidak ada yang tahu mana yang sudah
diproses. Kalau admin lalu mengklik ulang, sebagian refund berpotensi dikirim
dua kali.

Yang saya rancang: permintaan admin hanya mencatat keputusannya, dalam satu
transaksi.

```sql
BEGIN;
  UPDATE showtimes SET status = 'CANCELLED' WHERE id = $1;
  INSERT INTO showtime_cancellations (showtime_id, admin_id, reason) VALUES (...);
  INSERT INTO jobs (type, payload)
    SELECT 'refund', jsonb_build_object('order_id', id)
    FROM orders WHERE showtime_id = $1 AND status = 'PAID';   -- ±200 baris
  INSERT INTO jobs (type, payload)
    SELECT 'notify_cancellation', jsonb_build_object('order_id', id)
    FROM orders WHERE showtime_id = $1 AND status = 'PAID';
COMMIT;
```

Semuanya harus berada dalam satu transaksi. Kalau daftar pekerjaan refund
ditulis di langkah terpisah, ada kemungkinan jadwal tercatat dibatalkan
sementara perintah refundnya tidak pernah masuk daftar: 200 orang tidak mendapat
uangnya kembali, dan tidak ada error apa pun yang muncul.

Pemberitahuan ke customer juga masuk antrean pada transaksi yang sama, terpisah
dari refundnya, karena waktunya berbeda. Refund bisa memakan satu sampai tujuh
hari kerja, sedangkan customer perlu tahu sekarang bahwa jadwalnya dibatalkan
supaya tidak berangkat ke bioskop untuk jadwal yang sudah tidak ada.

Catatan pembatalannya menyimpan siapa admin yang membatalkan, kapan, alasannya,
serta berapa pesanan dan berapa nilai yang terdampak. Pembatalan menyentuh uang
banyak orang, jadi harus ada jejaknya.

Pekerjaan refundnya sendiri dikerjakan worker di latar belakang. Daftar
pekerjaan itu saya simpan sebagai tabel di PostgreSQL, bukan pada perangkat
antrean tersendiri, supaya bisa masuk satu transaksi seperti di atas dan tidak
menambah komponen yang harus dipasang serta diawasi. Worker mengambilnya dengan
`SELECT ... FOR UPDATE SKIP LOCKED`, sehingga beberapa worker bisa bekerja dari
daftar yang sama tanpa saling menunggu.

### 5.2 Refund berjalan asinkron dan bisa gagal

Uangnya ada di bank atau e-wallet, pengembaliannya butuh waktu, dan bisa gagal
karena kartu kedaluwarsa atau akun ditutup. Karena itu refund punya status
sendiri:

```
REQUESTED ──► PROCESSING ──► SUCCEEDED
                          └─► FAILED ──► dicoba ulang 3× (1, 3, 9 menit)
                                      └─► masih gagal: alert ke tim
```

Saat refund `SUCCEEDED`, pesanannya ditandai `REFUNDED`, perpindahan kursi
`SOLD → REFUNDED` dicatat di tabel riwayat, dan customer diberi tahu. Refund
`FAILED` wajib memicu alert, karena artinya ada customer yang uangnya tersangkut
dan orang itu belum tentu mengeluh.

### 5.3 Satu pembayaran hanya boleh direfund sekali

Notifikasi dari payment gateway bisa datang dua kali, worker bisa mati setelah
mengirim perintah refund tetapi sebelum mencatatnya, dan admin bisa mengklik
"Batalkan" lebih dari sekali. Tanpa penjagaan, ketiganya berarti uang keluar
berkali-kali.

Penjagaannya di dua tempat. Di database, `UNIQUE (payment_id)` pada tabel
`refunds` menolak percobaan kedua. Ke payment gateway, setiap perintah refund
membawa kunci yang sama (`refund-{order_id}`) sehingga gateway mengenali
permintaan berulang dan tidak mengirim uang untuk kedua kalinya.

---

## 6. Pembayaran: notifikasi tidak bisa diandalkan

Uang dipegang pihak ketiga, dan notifikasi pembayaran (webhook) bisa terlambat,
datang dua kali, atau hilang. Dua hal yang saya siapkan, keduanya karena
menyentuh kepemilikan kursi.

**Tenggat tagihan disamakan dengan tenggat pegangan kursi.** Saat meminta
tagihan, sistem meneruskan `orders.expires_at` apa adanya sebagai batas
pembayaran, bukan durasi "7 menit dari sekarang". Akibatnya berapa lama pun user
memilih metode pembayaran, tenggatnya tidak bergeser, dan hitung mundur yang
dilihat user tetap satu dari awal sampai akhir. Pembayaran yang lewat tenggat itu
ditolak oleh gateway, jadi uangnya tidak pernah keluar.

**Notifikasi ganda ditangkis idempotency.** Referensi pembayaran dari gateway
disimpan dengan `UNIQUE (provider, payment_reference)`; pemrosesan kedua tidak
melakukan apa pun dan tetap dijawab `200 OK`.

Sisanya adalah kasus yang tidak bisa dicegah, hanya dikompensasi: user membayar
sebelum tenggat tetapi kabarnya sampai setelah kursinya diambil pesanan lain.
Di situ perintah `UPDATE ... AND held_by_order = pesanan ini` mengembalikan nol
baris. Itu jawaban yang pasti, bukan dugaan, dan sistem langsung menjalankan
refund otomatis.

Perhatikan bahwa pegangan kursi yang kedaluwarsa tidak dihapus siapa pun,
`held_by_order` tetap berisi nomor pesanan yang lama. Jadi kalau ternyata tidak
ada yang mengambil kursi itu selama jeda tersebut, syaratnya tetap terpenuhi dan
tiketnya tetap terbit tanpa refund. Refund otomatis hanya terjadi kalau kabar
pembayaran terlambat **dan** kursinya benar-benar diperebutkan.

Untuk notifikasi yang hilang, sistem menanyakan status ke gateway sekali sebelum
pegangan kursi dilepas, dan ada pencocokan harian antara catatan kami dengan
laporan gateway.

---

## 7. Topologi dan pembagian tanggung jawab

![Topologi sistem](diagrams/1-topologi-sistem.jpg)

Sumber: [`1-topologi-sistem.drawio`](diagrams/1-topologi-sistem.drawio)

Aturan yang saya pakai saat menyusunnya: setiap komponen harus bisa dijawab
"kenapa ini ada?".

| Komponen | Tanggung jawab |
| -------- | -------------- |
| API (satu deployment, banyak modul, *stateless*) | Seluruh logika. Tidak menyimpan keadaan di memorinya sendiri, jadi jumlah instance bisa ditambah atau dikurangi bebas |
| Worker (dipisah sejak awal) | Refund massal, percobaan ulang, pencocokan, pengiriman e-ticket |
| Redis | Cache denah kursi. Percepatan pembacaan, tidak ikut memutuskan kepemilikan |
| PostgreSQL primary | Penentu kebenaran. Semua penulisan kursi dan uang |
| Monitoring dan alert | Refund gagal dan selisih pencocokan harus ada yang mengetahui |

Modul `auth`, `catalog`, `booking`, `payment`, dan `notification` saya gambar di
dalam satu deployment, bukan sebagai layanan terpisah. Memisahkannya sejak awal
menambah biaya nyata, yaitu transaksi lintas layanan dan penelusuran masalah yang
menyebar, tanpa manfaat pada skala ini. Yang saya pisahkan sejak awal hanya
worker, karena sifat kerjanya berbeda: berjalan di latar belakang, punya
percobaan ulang sendiri, dan tidak terikat pada permintaan HTTP.

Bagian yang saya implementasikan pada Poin C, yaitu API login dan CRUD jadwal
tayang, berada di modul `auth` dan `catalog`. Di dalam kode keduanya menjadi
paket `internal/auth` dan `internal/showtime`.

---

## 8. Batasan dan asumsi

Dokumen ini adalah rancangan, bukan laporan sistem yang sudah berjalan.

- Perkiraan beban bersifat asumsi, bukan data lapangan. Yang saya jadikan dasar
  adalah sifat bebannya: pembacaan denah kursi jauh lebih banyak daripada
  pembelian, dan beban terberat terjadi pada satu jadwal yang sama.
- Yang saya implementasikan dalam tes ini adalah Poin C, yaitu API login dan
  CRUD jadwal tayang. Modul `booking`, `payment`, dan `notification` pada
  topologi hanya dirancang, tidak dikerjakan.
- Pertimbangan seperti tenggat pembayaran absolut, pencocokan berkala, dan refund
  otomatis saat kursi bentrok saya sertakan karena menurut analisa saya kasus itu
  akan terjadi pada sistem seperti ini, bukan karena saya sudah pernah
  menanganinya di lingkungan produksi.
- Angka 7 menit untuk masa tahan kursi dan 30 menit untuk batas penjualan ulang
  adalah nilai awal lewat konfigurasi, dipilih karena sebanding dengan waktu yang
  umumnya dibutuhkan untuk membayar, bukan hasil pengukuran.
- Nama produk yang disebut (Midtrans, Xendit, dan sejenisnya) adalah contoh.
  Yang saya tetapkan adalah perannya di dalam sistem.
- Yang belum saya rancang: angka pembatasan kuota per akun pada halaman denah
  kursi, dan perilaku sistem saat payment gateway tidak bisa dihubungi sama
  sekali dalam waktu lama.
