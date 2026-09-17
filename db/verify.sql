-- =============================================================================
--  Uji perilaku rancangan - Poin B
--  Menjalankan:  psql -U <user> -d mkp_cinema -f db/verify.sql
--
--  Seluruh uji dibungkus transaksi dan di-ROLLBACK, jadi tidak meninggalkan data.
--  Aman dijalankan pada basis data yang masih kosong maupun yang sudah diisi
--  db/seed.sql: semua id contoh memakai rentang 9xxx supaya tidak berbenturan
--  dengan data seed.
-- =============================================================================
BEGIN;

-- ---- data secukupnya -------------------------------------------------------
INSERT INTO users (id, email, password_hash, full_name, role)
VALUES (9001,'budi@test.id','x','Budi','customer'), (9002,'siti@test.id','x','Siti','customer');

INSERT INTO cinemas (id, name, city) VALUES (9001,'MKP Bandung','Bandung');
INSERT INTO screens (id, cinema_id, name) VALUES (9001,9001,'Studio 1'), (9002,9001,'Studio 2');
INSERT INTO seats (id, screen_id, row_label, seat_number)
VALUES (9001,9001,'A',5),(9002,9001,'A',6),(9003,9001,'A',7),
       (9011,9002,'A',1),(9012,9002,'A',2);
INSERT INTO movies (id, title, duration_minutes) VALUES (9001,'Film Uji',120);
INSERT INTO showtimes (id, movie_id, screen_id, start_time, end_time, price)
VALUES (9001,9001,9001,'2026-10-01 19:00+07','2026-10-01 21:00+07',50000);

-- id di atas diisi manual, jadi urutan otomatisnya perlu dimajukan melewati
-- rentang 9xxx sekaligus melewati apa pun yang sudah dipakai db/seed.sql
SELECT setval(pg_get_serial_sequence(t,'id'), 100000)
FROM unnest(ARRAY['users','cinemas','screens','seats','movies','showtimes',
                  'orders','tickets','payments']) AS t;

\echo '--------------------------------------------------------------'

-- A. kursi dibuat otomatis oleh trigger
SELECT CASE WHEN count(*) = 3 THEN 'PASS' ELSE 'FAIL' END AS hasil,
       'A. showtime_seats dibuat otomatis saat jadwal dibuat (' || count(*) || ' kursi)' AS uji
FROM showtime_seats WHERE showtime_id = 9001;

-- B. jadwal bertumpuk di studio yang sama ditolak
DO $$
BEGIN
    INSERT INTO showtimes (movie_id, screen_id, start_time, end_time, price)
    VALUES (9001,9001,'2026-10-01 20:00+07','2026-10-01 22:00+07',50000);
    RAISE NOTICE 'FAIL  B. jadwal bertumpuk TERNYATA diterima';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'PASS  B. jadwal bertumpuk di studio yang sama ditolak';
END $$;

-- C. klaim kursi: yang kedua mengembalikan 0 baris
INSERT INTO orders (id, user_id, showtime_id, expires_at)
VALUES (9881,9001,9001, now() + interval '7 minutes'), (9903,9002,9001, now() + interval '7 minutes');

DO $$
DECLARE n1 INT; n2 INT;
BEGIN
    WITH u AS (
        UPDATE showtime_seats SET status='held', held_by_order=9881, expires_at=now()+interval '7 minutes'
        WHERE showtime_id=9001 AND seat_id=9001
          AND (status='available' OR (status='held' AND expires_at <= now()))
        RETURNING 1) SELECT count(*) INTO n1 FROM u;

    WITH u AS (
        UPDATE showtime_seats SET status='held', held_by_order=9903, expires_at=now()+interval '7 minutes'
        WHERE showtime_id=9001 AND seat_id=9001
          AND (status='available' OR (status='held' AND expires_at <= now()))
        RETURNING 1) SELECT count(*) INTO n2 FROM u;

    IF n1 = 1 AND n2 = 0
      THEN RAISE NOTICE 'PASS  C. klaim pertama 1 baris, klaim kedua % baris', n2;
      ELSE RAISE NOTICE 'FAIL  C. hasil % dan %', n1, n2; END IF;
END $$;

-- D. pegangan kedaluwarsa boleh diambil alih
DO $$
DECLARE n INT;
BEGIN
    UPDATE showtime_seats SET expires_at = now() - interval '1 second'
    WHERE showtime_id=9001 AND seat_id=9001;

    WITH u AS (
        UPDATE showtime_seats SET status='held', held_by_order=9903, expires_at=now()+interval '7 minutes'
        WHERE showtime_id=9001 AND seat_id=9001
          AND (status='available' OR (status='held' AND expires_at <= now()))
        RETURNING 1) SELECT count(*) INTO n FROM u;

    IF n = 1 THEN RAISE NOTICE 'PASS  D. pegangan kedaluwarsa diambil alih tanpa ada yang menghapusnya';
             ELSE RAISE NOTICE 'FAIL  D. hasil %', n; END IF;
END $$;

-- E. keadaan mustahil ditolak CHECK
DO $$
BEGIN
    UPDATE showtime_seats SET status='sold', expires_at=now()+interval '1 hour'
    WHERE showtime_id=9001 AND seat_id=9002;
    RAISE NOTICE 'FAIL  E. status sold dengan expires_at TERNYATA diterima';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS  E. kombinasi status/held_by_order/expires_at yang mustahil ditolak';
END $$;

-- F. satu kursi hanya boleh punya satu tiket berlaku, tapi boleh dijual ulang
INSERT INTO tickets (id, order_id, showtime_id, seat_id, price, qr_code)
VALUES (9001, 9881, 9001, 9003, 50000, 'QR-UJI-1');

DO $$
BEGIN
    INSERT INTO tickets (order_id, showtime_id, seat_id, price, qr_code)
    VALUES (9903, 9001, 9003, 50000, 'QR-UJI-2');
    RAISE NOTICE 'FAIL  F1. tiket kedua untuk kursi yang sama TERNYATA diterima';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS  F1. tiket kedua untuk kursi yang masih berlaku ditolak';
END $$;

DO $$
BEGIN
    UPDATE tickets SET status='refunded' WHERE id=9001;
    INSERT INTO tickets (order_id, showtime_id, seat_id, price, qr_code)
    VALUES (9903, 9001, 9003, 50000, 'QR-UJI-2');
    RAISE NOTICE 'PASS  F2. setelah tiket lama direfund, kursi boleh dijual ulang';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'FAIL  F2. penjualan ulang setelah refund ikut tertolak';
END $$;

-- G. satu pembayaran hanya boleh punya satu refund
INSERT INTO payments (id, order_id, provider, payment_reference, amount, status, expires_at, paid_at)
VALUES (9001, 9881, 'midtrans', 'PAY-UJI-001', 50000, 'paid', now()+interval '7 minutes', now());
INSERT INTO refunds (payment_id, amount, reason) VALUES (9001, 50000, 'seat_conflict');

DO $$
BEGIN
    INSERT INTO refunds (payment_id, amount, reason) VALUES (9001, 50000, 'seat_conflict');
    RAISE NOTICE 'FAIL  G. refund kedua untuk pembayaran yang sama TERNYATA diterima';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS  G. refund kedua untuk pembayaran yang sama ditolak';
END $$;

-- H. notifikasi pembayaran yang sama tidak bisa masuk dua kali
DO $$
BEGIN
    INSERT INTO payments (order_id, provider, payment_reference, amount, status, expires_at)
    VALUES (9903, 'midtrans', 'PAY-UJI-001', 50000, 'pending', now()+interval '7 minutes');
    RAISE NOTICE 'FAIL  H. payment_reference ganda TERNYATA diterima';
EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS  H. payment_reference ganda ditolak (idempotency webhook)';
END $$;

-- I. pola UPDATE yang dipakai API Poin C: pegangan kursi yang masih hidup
--    menahan perubahan jadwal, pegangan yang sudah kedaluwarsa tidak
DO $$
DECLARE n INT;
BEGIN
    -- uji C sampai F meninggalkan pegangan dan tiket pada jadwal 9001;
    -- dikembalikan ke keadaan bersih supaya yang diuji di sini hanya satu hal
    UPDATE tickets SET status='refunded' WHERE showtime_id=9001;
    UPDATE showtime_seats SET status='available', held_by_order=NULL, expires_at=NULL
    WHERE showtime_id=9001;

    -- kursi 9002 dipegang pesanan 9903, masih 7 menit lagi
    UPDATE showtime_seats SET status='held', held_by_order=9903, expires_at=now()+interval '7 minutes'
    WHERE showtime_id=9001 AND seat_id=9002;

    WITH u AS (
        UPDATE showtimes s SET start_time='2026-10-02 19:00+07', end_time='2026-10-02 21:00+07'
          FROM movies m
         WHERE s.id=9001 AND s.status='scheduled' AND s.screen_id=9001
           AND m.id=9001 AND m.is_active
           AND NOT EXISTS (SELECT 1 FROM tickets t WHERE t.showtime_id=s.id AND t.status='valid')
           AND NOT EXISTS (SELECT 1 FROM showtime_seats ss WHERE ss.showtime_id=s.id
                            AND (ss.status='sold' OR (ss.status='held' AND ss.expires_at > now())))
        RETURNING 1) SELECT count(*) INTO n FROM u;

    IF n = 0 THEN RAISE NOTICE 'PASS  I1. jadwal dengan pegangan kursi hidup tidak bisa diubah';
             ELSE RAISE NOTICE 'FAIL  I1. ternyata terubah % baris', n; END IF;

    -- pegangan yang sama dibiarkan kedaluwarsa
    UPDATE showtime_seats SET expires_at=now()-interval '1 second'
    WHERE showtime_id=9001 AND seat_id=9002;

    WITH u AS (
        UPDATE showtimes s SET start_time='2026-10-02 19:00+07', end_time='2026-10-02 21:00+07'
          FROM movies m
         WHERE s.id=9001 AND s.status='scheduled' AND s.screen_id=9001
           AND m.id=9001 AND m.is_active
           AND NOT EXISTS (SELECT 1 FROM tickets t WHERE t.showtime_id=s.id AND t.status='valid')
           AND NOT EXISTS (SELECT 1 FROM showtime_seats ss WHERE ss.showtime_id=s.id
                            AND (ss.status='sold' OR (ss.status='held' AND ss.expires_at > now())))
        RETURNING 1) SELECT count(*) INTO n FROM u;

    IF n = 1 THEN RAISE NOTICE 'PASS  I2. pegangan yang kedaluwarsa tidak lagi menahan perubahan';
             ELSE RAISE NOTICE 'FAIL  I2. hasil %', n; END IF;
END $$;

-- J. memindahkan jadwal ke studio lain tidak ikut memindahkan peta kursinya,
--    karena itu API Poin C menolak perubahan screen_id
DO $$
DECLARE n INT; kursi_studio TEXT;
BEGIN
    SELECT string_agg(DISTINCT s.screen_id::text, ',') INTO kursi_studio
      FROM showtime_seats ss JOIN seats s ON s.id = ss.seat_id
     WHERE ss.showtime_id = 9001;

    -- pemindahan tanpa penjaga: jadwal berpindah, peta kursi tertinggal
    UPDATE showtimes SET screen_id = 9002 WHERE id = 9001;
    IF (SELECT string_agg(DISTINCT s.screen_id::text, ',')
          FROM showtime_seats ss JOIN seats s ON s.id = ss.seat_id
         WHERE ss.showtime_id = 9001) = kursi_studio
      THEN RAISE NOTICE 'PASS  J1. peta kursi memang TERTINGGAL di studio % setelah jadwal dipindah', kursi_studio;
      ELSE RAISE NOTICE 'FAIL  J1. peta kursi ternyata ikut berpindah'; END IF;
    UPDATE showtimes SET screen_id = 9001 WHERE id = 9001;

    -- penjaga API: syarat s.screen_id = <yang dikirim> membuat pemindahan nol baris
    WITH u AS (
        UPDATE showtimes s SET price = 60000
          FROM movies m
         WHERE s.id=9001 AND s.status='scheduled' AND s.screen_id=9002
           AND m.id=9001 AND m.is_active
        RETURNING 1) SELECT count(*) INTO n FROM u;

    IF n = 0 THEN RAISE NOTICE 'PASS  J2. permintaan yang mengubah screen_id ditolak (0 baris)';
             ELSE RAISE NOTICE 'FAIL  J2. hasil %', n; END IF;
END $$;

\echo '--------------------------------------------------------------'
ROLLBACK;
