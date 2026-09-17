-- =============================================================================
--  Data contoh - Poin B
--  Jalankan setelah schema.sql:
--      psql -U <user> -d mkp_cinema -f db/seed.sql
--
--  Isinya cukup untuk mencoba seluruh alur: katalog 2 kota, jadwal tayang untuk
--  beberapa hari ke depan, serta pesanan dalam berbagai keadaan (lunas, sedang
--  dipegang, pegangan kedaluwarsa, dan yang sudah direfund).
--
--  Akun untuk mencoba API Poin C:
--      budi@mail.test   / password123   (customer)
--      admin@mkp.test   / admin123      (cinema_admin)
--  Kata sandi disimpan sebagai bcrypt, bukan teks polos.
-- =============================================================================

-- ---------------------------------------------------------------------------
--  1. Pengguna
-- ---------------------------------------------------------------------------
INSERT INTO users (email, password_hash, full_name, phone, role) VALUES
  ('budi@mail.test',  '$2a$10$OnrwE1aqxMka7XbnLQ5HXO5iGJMUMyh7rmL34KXyWCjck4dNCmuwW', 'Budi Santoso',  '081200000001', 'customer'),
  ('siti@mail.test',  '$2a$10$OnrwE1aqxMka7XbnLQ5HXO5iGJMUMyh7rmL34KXyWCjck4dNCmuwW', 'Siti Rahayu',   '081200000002', 'customer'),
  ('rian@mail.test',  '$2a$10$OnrwE1aqxMka7XbnLQ5HXO5iGJMUMyh7rmL34KXyWCjck4dNCmuwW', 'Rian Pratama',  '081200000003', 'customer'),
  ('admin@mkp.test',  '$2a$10$0zTLaIFV0TQsdFM6rdYyVuOdxlfCS8Iva5SkSHk9gxy8lKYLV8pVm', 'Admin Bandung', '081200000010', 'cinema_admin'),
  ('admin2@mkp.test', '$2a$10$0zTLaIFV0TQsdFM6rdYyVuOdxlfCS8Iva5SkSHk9gxy8lKYLV8pVm', 'Admin Jakarta', '081200000011', 'cinema_admin');

-- ---------------------------------------------------------------------------
--  2. Bioskop dan studio
-- ---------------------------------------------------------------------------
INSERT INTO cinemas (name, city, address) VALUES
  ('MKP Cinema Dago',        'Bandung', 'Jl. Ir. H. Juanda No. 100, Bandung'),
  ('MKP Cinema Buah Batu',   'Bandung', 'Jl. Buah Batu No. 25, Bandung'),
  ('MKP Cinema Kuningan',    'Jakarta', 'Jl. HR Rasuna Said Kav. 5, Jakarta Selatan');

INSERT INTO screens (cinema_id, name)
SELECT c.id, s.name
FROM cinemas c
CROSS JOIN (VALUES ('Studio 1'), ('Studio 2')) AS s(name);

-- Kursi: baris A-H, nomor 1-14 → 112 kursi per studio.
-- Baris G dan H ditandai kelas premiere.
INSERT INTO seats (screen_id, row_label, seat_number, seat_class)
SELECT sc.id,
       r.label,
       n.num,
       CASE WHEN r.label IN ('G','H') THEN 'premiere' ELSE 'regular' END
FROM screens sc
CROSS JOIN (VALUES ('A'),('B'),('C'),('D'),('E'),('F'),('G'),('H')) AS r(label)
CROSS JOIN generate_series(1, 14) AS n(num);

-- ---------------------------------------------------------------------------
--  3. Film
-- ---------------------------------------------------------------------------
INSERT INTO movies (title, duration_minutes, rating, synopsis, poster_url) VALUES
  ('Lorong Waktu',      118, '13+', 'Seorang teknisi menemukan mesin tua yang mengirimnya ke masa lalu.', 'https://cdn.example.test/poster/lorong-waktu.jpg'),
  ('Senja di Jakarta',   96, 'SU',  'Dua sahabat lama bertemu kembali di sebuah stasiun tua.',           'https://cdn.example.test/poster/senja-di-jakarta.jpg'),
  ('Operasi Senyap',    134, '17+', 'Satu regu kecil dikirim ke perbatasan tanpa perintah tertulis.',    'https://cdn.example.test/poster/operasi-senyap.jpg'),
  ('Kembali ke Rumah',  105, 'SU',  'Perjalanan pulang yang berubah arah karena satu panggilan telepon.', 'https://cdn.example.test/poster/kembali-ke-rumah.jpg');

-- ---------------------------------------------------------------------------
--  4. Jadwal tayang
--     Empat sesi per studio per hari, untuk 3 hari ke depan.
--     Jam sesi dibuat tidak bertumpuk supaya lolos EXCLUDE constraint.
-- ---------------------------------------------------------------------------
INSERT INTO showtimes (movie_id, screen_id, start_time, end_time, price)
SELECT
    m.id,
    sc.id,
    slot.ts,
    slot.ts + make_interval(mins => m.duration_minutes),
    CASE WHEN EXTRACT(dow FROM slot.ts) IN (0, 6) THEN 60000 ELSE 45000 END
FROM screens sc
CROSS JOIN LATERAL (
    SELECT (current_date + d)::timestamptz + h AS ts
    FROM generate_series(0, 2) AS d
    CROSS JOIN unnest(ARRAY['13:00','16:00','19:00','21:30']::interval[]) AS h
) AS slot
-- film dipilih bergiliran supaya tiap studio menayangkan judul berbeda
CROSS JOIN LATERAL (
    SELECT * FROM movies
    ORDER BY (sc.id + EXTRACT(hour FROM slot.ts)::int) % 4, id
    LIMIT 1
) AS m;

-- Catatan: baris showtime_seats untuk setiap jadwal dibuat OTOMATIS oleh
-- trigger showtimes_generate_seats. Tidak perlu disisipkan di sini.

-- ---------------------------------------------------------------------------
--  5. Pesanan contoh - empat keadaan berbeda
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_showtime  BIGINT;
    v_budi      BIGINT;
    v_siti      BIGINT;
    v_rian      BIGINT;
    v_admin     BIGINT;
    v_price     NUMERIC(12,2);
    v_order     BIGINT;
    v_payment   BIGINT;
    v_seat      BIGINT;
    v_seats     BIGINT[];
BEGIN
    SELECT id INTO v_budi  FROM users WHERE email = 'budi@mail.test';
    SELECT id INTO v_siti  FROM users WHERE email = 'siti@mail.test';
    SELECT id INTO v_rian  FROM users WHERE email = 'rian@mail.test';
    SELECT id INTO v_admin FROM users WHERE email = 'admin@mkp.test';

    -- jadwal terdekat hari ini di studio pertama
    SELECT id, price INTO v_showtime, v_price
    FROM showtimes ORDER BY start_time, id LIMIT 1;

    -- === (a) PESANAN LUNAS: dua kursi terjual, tiket terbit =================
    INSERT INTO orders (user_id, showtime_id, status, total_amount, expires_at)
    VALUES (v_budi, v_showtime, 'PAID', v_price * 2, now() + interval '7 minutes')
    RETURNING id INTO v_order;

    SELECT array_agg(seat_id) INTO v_seats FROM (
        SELECT ss.seat_id FROM showtime_seats ss
        JOIN seats s ON s.id = ss.seat_id
        WHERE ss.showtime_id = v_showtime AND s.row_label = 'C' AND s.seat_number IN (5, 6)
    ) q;

    UPDATE showtime_seats
    SET status = 'sold', held_by_order = v_order, expires_at = NULL
    WHERE showtime_id = v_showtime AND seat_id = ANY(v_seats);

    INSERT INTO tickets (order_id, showtime_id, seat_id, price, qr_code)
    SELECT v_order, v_showtime, s, v_price, 'MKP-' || v_order || '-' || s
    FROM unnest(v_seats) AS s;

    INSERT INTO payments (order_id, provider, payment_reference, amount, status, expires_at, paid_at)
    VALUES (v_order, 'midtrans', 'MID-SEED-0001', v_price * 2, 'paid',
            now() + interval '7 minutes', now() - interval '2 hours');

    INSERT INTO seat_inventory_ledger (showtime_id, seat_id, from_status, to_status, reason, ref_type, ref_id)
    SELECT v_showtime, s, 'available', 'held', 'user_select', 'order', v_order FROM unnest(v_seats) AS s
    UNION ALL
    SELECT v_showtime, s, 'held', 'sold', 'payment_settled', 'order', v_order FROM unnest(v_seats) AS s;

    -- === (b) PEGANGAN AKTIF: kursi sedang diproses orang lain ===============
    INSERT INTO orders (user_id, showtime_id, status, total_amount, expires_at)
    VALUES (v_siti, v_showtime, 'AWAITING_PAYMENT', v_price, now() + interval '5 minutes')
    RETURNING id INTO v_order;

    SELECT ss.seat_id INTO v_seat FROM showtime_seats ss
    JOIN seats s ON s.id = ss.seat_id
    WHERE ss.showtime_id = v_showtime AND s.row_label = 'C' AND s.seat_number = 7;

    UPDATE showtime_seats
    SET status = 'held', held_by_order = v_order, expires_at = now() + interval '5 minutes'
    WHERE showtime_id = v_showtime AND seat_id = v_seat;

    INSERT INTO payments (order_id, provider, payment_reference, amount, status, expires_at)
    VALUES (v_order, 'midtrans', 'MID-SEED-0002', v_price, 'pending', now() + interval '5 minutes');

    INSERT INTO seat_inventory_ledger (showtime_id, seat_id, from_status, to_status, reason, ref_type, ref_id)
    VALUES (v_showtime, v_seat, 'available', 'held', 'user_select', 'order', v_order);

    -- === (c) PEGANGAN KEDALUWARSA: kursi boleh diambil alih =================
    --     Sengaja dibiarkan tidak dibersihkan - memang begitu rancangannya.
    INSERT INTO orders (user_id, showtime_id, status, total_amount, expires_at)
    VALUES (v_rian, v_showtime, 'FAILED', v_price, now() - interval '30 minutes')
    RETURNING id INTO v_order;

    SELECT ss.seat_id INTO v_seat FROM showtime_seats ss
    JOIN seats s ON s.id = ss.seat_id
    WHERE ss.showtime_id = v_showtime AND s.row_label = 'C' AND s.seat_number = 8;

    UPDATE showtime_seats
    SET status = 'held', held_by_order = v_order, expires_at = now() - interval '23 minutes'
    WHERE showtime_id = v_showtime AND seat_id = v_seat;

    INSERT INTO seat_inventory_ledger (showtime_id, seat_id, from_status, to_status, reason, ref_type, ref_id)
    VALUES (v_showtime, v_seat, 'available', 'held', 'user_select', 'order', v_order);

    -- === (d) JADWAL DIBATALKAN BIOSKOP + refund berhasil ====================
    DECLARE
        v_cancelled BIGINT;
    BEGIN
        SELECT id, price INTO v_cancelled, v_price
        FROM showtimes ORDER BY start_time DESC, id DESC LIMIT 1;

        INSERT INTO orders (user_id, showtime_id, status, total_amount, expires_at)
        VALUES (v_siti, v_cancelled, 'REFUNDED', v_price, now() - interval '1 day')
        RETURNING id INTO v_order;

        SELECT ss.seat_id INTO v_seat FROM showtime_seats ss
        JOIN seats s ON s.id = ss.seat_id
        WHERE ss.showtime_id = v_cancelled AND s.row_label = 'A' AND s.seat_number = 1;

        UPDATE showtime_seats
        SET status = 'sold', held_by_order = v_order, expires_at = NULL
        WHERE showtime_id = v_cancelled AND seat_id = v_seat;

        INSERT INTO tickets (order_id, showtime_id, seat_id, price, qr_code, status)
        VALUES (v_order, v_cancelled, v_seat, v_price, 'MKP-' || v_order || '-' || v_seat, 'refunded');

        INSERT INTO payments (order_id, provider, payment_reference, amount, status, expires_at, paid_at)
        VALUES (v_order, 'xendit', 'XND-SEED-0003', v_price, 'paid',
                now() - interval '1 day', now() - interval '1 day')
        RETURNING id INTO v_payment;

        INSERT INTO refunds (payment_id, amount, reason, status, gateway_reference)
        VALUES (v_payment, v_price, 'cinema_cancel', 'SUCCEEDED', 'XND-RFD-0003');

        UPDATE showtimes SET status = 'cancelled' WHERE id = v_cancelled;

        INSERT INTO showtime_cancellations (showtime_id, cancelled_by, reason, affected_orders, affected_amount)
        VALUES (v_cancelled, v_admin, 'Proyektor studio bermasalah', 1, v_price);

        INSERT INTO seat_inventory_ledger (showtime_id, seat_id, from_status, to_status, reason, ref_type, ref_id)
        VALUES (v_cancelled, v_seat, 'sold', 'refunded', 'cinema_cancel', 'order', v_order);

        -- pekerjaan latar belakang yang menyertai pembatalan
        INSERT INTO jobs (type, payload, status) VALUES
          ('refund',              jsonb_build_object('order_id', v_order), 'done'),
          ('notify_cancellation', jsonb_build_object('order_id', v_order), 'done');
    END;

    -- satu pekerjaan yang masih menunggu, untuk mencoba worker
    INSERT INTO jobs (type, payload, status, run_after)
    VALUES ('send_eticket', jsonb_build_object('order_id', 1), 'pending', now());
END $$;

-- ---------------------------------------------------------------------------
--  6. Ringkasan
-- ---------------------------------------------------------------------------
SELECT 'users'          AS tabel, count(*) AS jumlah FROM users
UNION ALL SELECT 'cinemas',        count(*) FROM cinemas
UNION ALL SELECT 'screens',        count(*) FROM screens
UNION ALL SELECT 'seats',          count(*) FROM seats
UNION ALL SELECT 'movies',         count(*) FROM movies
UNION ALL SELECT 'showtimes',      count(*) FROM showtimes
UNION ALL SELECT 'showtime_seats', count(*) FROM showtime_seats
UNION ALL SELECT 'orders',         count(*) FROM orders
UNION ALL SELECT 'tickets',        count(*) FROM tickets
UNION ALL SELECT 'payments',       count(*) FROM payments
UNION ALL SELECT 'refunds',        count(*) FROM refunds
UNION ALL SELECT 'ledger',         count(*) FROM seat_inventory_ledger
UNION ALL SELECT 'cancellations',  count(*) FROM showtime_cancellations
UNION ALL SELECT 'jobs',           count(*) FROM jobs
ORDER BY 1;
