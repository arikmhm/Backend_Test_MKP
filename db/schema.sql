-- =============================================================================
--  Platform Pembelian Tiket Bioskop Online
--  Backend Development Test - Mitra Kasih Perkasa 2025 - Poin B
--
--  PostgreSQL 13+
--  Jalankan:  createdb mkp_cinema
--             psql -U <user> -d mkp_cinema -f db/schema.sql
--
--  Catatan rancangan:
--  - Status disimpan sebagai TEXT + CHECK, bukan tipe ENUM. Alasannya menambah
--    nilai baru cukup mengubah CHECK, tidak perlu ALTER TYPE yang mengunci tabel.
--  - Semua waktu memakai TIMESTAMPTZ. Tenggat dikirim ke pihak luar sebagai
--    waktu absolut, sehingga zona waktu harus ikut tersimpan.
--  - Uang memakai NUMERIC(12,2), tidak pernah FLOAT.
-- =============================================================================

-- Dibutuhkan oleh EXCLUDE constraint pada tabel showtimes (lihat bagian 2.5)
CREATE EXTENSION IF NOT EXISTS btree_gist;


-- =============================================================================
--  0. Utilitas
-- =============================================================================

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION set_updated_at() IS
    'Mengisi kolom updated_at setiap kali baris diubah.';


-- =============================================================================
--  1. Pengguna
-- =============================================================================

CREATE TABLE users (
    id            BIGSERIAL    PRIMARY KEY,
    email         TEXT         NOT NULL,
    password_hash TEXT         NOT NULL,
    full_name     TEXT         NOT NULL,
    phone         TEXT,
    role          TEXT         NOT NULL DEFAULT 'customer',
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT users_email_unique UNIQUE (email),
    CONSTRAINT users_role_check   CHECK (role IN ('customer', 'cinema_admin'))
);

CREATE TRIGGER users_set_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  users      IS 'Akun customer dan petugas bioskop. Satu tabel untuk dua peran, dibedakan kolom role.';
COMMENT ON COLUMN users.role IS 'customer = pembeli tiket; cinema_admin = petugas yang mengelola jadwal tayang.';


-- =============================================================================
--  2. Katalog - data publik, boleh dibaca sebelum masuk akun
-- =============================================================================

-- 2.1 Bioskop -----------------------------------------------------------------
CREATE TABLE cinemas (
    id         BIGSERIAL    PRIMARY KEY,
    name       TEXT         NOT NULL,
    city       TEXT         NOT NULL,
    address    TEXT,
    is_active  BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX cinemas_city_idx ON cinemas (city) WHERE is_active;

CREATE TRIGGER cinemas_set_updated_at BEFORE UPDATE ON cinemas
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  cinemas      IS 'Cabang bioskop. Jaringan nasional, satu kota bisa punya beberapa cabang.';
COMMENT ON COLUMN cinemas.city IS 'Kota disimpan sebagai kolom, bukan tabel tersendiri - belum ada kebutuhan yang menuntutnya.';

-- 2.2 Studio ------------------------------------------------------------------
CREATE TABLE screens (
    id         BIGSERIAL    PRIMARY KEY,
    cinema_id  BIGINT       NOT NULL REFERENCES cinemas (id) ON DELETE RESTRICT,
    name       TEXT         NOT NULL,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT screens_name_unique UNIQUE (cinema_id, name)
);

CREATE TRIGGER screens_set_updated_at BEFORE UPDATE ON screens
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE screens IS 'Studio di dalam sebuah bioskop, misal "Studio 1".';

-- 2.3 Kursi fisik -------------------------------------------------------------
CREATE TABLE seats (
    id          BIGSERIAL   PRIMARY KEY,
    screen_id   BIGINT      NOT NULL REFERENCES screens (id) ON DELETE RESTRICT,
    row_label   TEXT        NOT NULL,
    seat_number INT         NOT NULL,
    seat_class  TEXT        NOT NULL DEFAULT 'regular',

    CONSTRAINT seats_position_unique  UNIQUE (screen_id, row_label, seat_number),
    CONSTRAINT seats_class_check      CHECK (seat_class IN ('regular', 'premiere')),
    CONSTRAINT seats_number_check     CHECK (seat_number > 0)
);

CREATE INDEX seats_screen_idx ON seats (screen_id);

COMMENT ON TABLE  seats            IS 'Kursi fisik di dalam studio. Dipakai ulang oleh semua jadwal tayang pada studio itu.';
COMMENT ON COLUMN seats.seat_class IS 'Disiapkan untuk pembedaan kelas kursi. Harga saat ini masih per jadwal, belum per kelas.';

-- 2.4 Film --------------------------------------------------------------------
CREATE TABLE movies (
    id               BIGSERIAL   PRIMARY KEY,
    title            TEXT        NOT NULL,
    duration_minutes INT         NOT NULL,
    rating           TEXT        NOT NULL DEFAULT 'SU',
    synopsis         TEXT,
    poster_url       TEXT,
    is_active        BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT movies_duration_check CHECK (duration_minutes > 0),
    CONSTRAINT movies_rating_check   CHECK (rating IN ('SU', '13+', '17+', '21+'))
);

CREATE TRIGGER movies_set_updated_at BEFORE UPDATE ON movies
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON COLUMN movies.poster_url IS 'Gambar poster dilayani CDN, bukan oleh API.';

-- 2.5 Jadwal tayang - CRUD-nya adalah Poin C ----------------------------------
CREATE TABLE showtimes (
    id         BIGSERIAL     PRIMARY KEY,
    movie_id   BIGINT        NOT NULL REFERENCES movies  (id) ON DELETE RESTRICT,
    screen_id  BIGINT        NOT NULL REFERENCES screens (id) ON DELETE RESTRICT,
    start_time TIMESTAMPTZ   NOT NULL,
    end_time   TIMESTAMPTZ   NOT NULL,
    price      NUMERIC(12,2) NOT NULL,
    status     TEXT          NOT NULL DEFAULT 'scheduled',
    created_at TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT showtimes_status_check CHECK (status IN ('scheduled', 'cancelled')),
    CONSTRAINT showtimes_price_check  CHECK (price >= 0),
    CONSTRAINT showtimes_time_check   CHECK (end_time > start_time),

    -- Dua jadwal tidak boleh bertumpuk di studio yang sama.
    -- Ditegakkan mesin database, bukan dicek oleh kode aplikasi.
    CONSTRAINT showtimes_no_overlap EXCLUDE USING gist (
        screen_id WITH =,
        tstzrange(start_time, end_time) WITH &&
    ) WHERE (status = 'scheduled')
);

-- Layar "pilih kota -> pilih film -> daftar bioskop, jam, harga"
CREATE INDEX showtimes_movie_time_idx  ON showtimes (movie_id, start_time) WHERE status = 'scheduled';
CREATE INDEX showtimes_screen_time_idx ON showtimes (screen_id, start_time);

CREATE TRIGGER showtimes_set_updated_at BEFORE UPDATE ON showtimes
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  showtimes          IS 'Jadwal tayang. API CRUD tabel inilah yang diimplementasikan pada Poin C.';
COMMENT ON COLUMN showtimes.price    IS 'Harga per kursi untuk jadwal ini. Sudah tampil di daftar jadwal, sebelum user memilih kursi.';
COMMENT ON COLUMN showtimes.end_time IS 'Disimpan, tidak dihitung ulang, supaya bisa dipakai EXCLUDE constraint anti-tumpuk.';


-- =============================================================================
--  3. Transaksi
-- =============================================================================

-- 3.1 Pesanan -----------------------------------------------------------------
CREATE TABLE orders (
    id           BIGSERIAL     PRIMARY KEY,
    user_id      BIGINT        NOT NULL REFERENCES users     (id) ON DELETE RESTRICT,
    showtime_id  BIGINT        NOT NULL REFERENCES showtimes (id) ON DELETE RESTRICT,
    status       TEXT          NOT NULL DEFAULT 'PENDING',
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
    expires_at   TIMESTAMPTZ   NOT NULL,
    created_at   TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT orders_status_check CHECK (status IN
        ('PENDING', 'AWAITING_PAYMENT', 'PAID', 'FAILED', 'CANCELLED', 'REFUNDED')),
    CONSTRAINT orders_amount_check CHECK (total_amount >= 0)
);

CREATE INDEX orders_user_idx     ON orders (user_id, created_at DESC);
CREATE INDEX orders_showtime_idx ON orders (showtime_id) WHERE status = 'PAID';

CREATE TRIGGER orders_set_updated_at BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  orders            IS 'Pesanan. Dibuat lebih dulu daripada klaim kursi, karena showtime_seats.held_by_order menunjuk ke sini.';
COMMENT ON COLUMN orders.status     IS 'PENDING = kursi dipegang, tagihan belum terbit. AWAITING_PAYMENT = tagihan sudah ada.';
COMMENT ON COLUMN orders.expires_at IS 'Tenggat tunggal seluruh alur. Nilai ini juga dikirim ke payment gateway sebagai batas pembayaran.';
COMMENT ON INDEX  orders_showtime_idx IS 'Dipakai saat pembatalan jadwal: mencari seluruh pesanan lunas pada satu jadwal.';

-- 3.2 Kursi per jadwal - inti rancangan Poin A --------------------------------
CREATE TABLE showtime_seats (
    showtime_id   BIGINT      NOT NULL REFERENCES showtimes (id) ON DELETE CASCADE,
    seat_id       BIGINT      NOT NULL REFERENCES seats     (id) ON DELETE RESTRICT,
    status        TEXT        NOT NULL DEFAULT 'available',
    held_by_order BIGINT               REFERENCES orders    (id) ON DELETE RESTRICT,
    expires_at    TIMESTAMPTZ,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Satu kursi pada satu jadwal = satu baris. Pemilik kedua tidak ditolak
    -- karena ada yang memeriksa, tetapi karena tidak ada tempat untuknya.
    PRIMARY KEY (showtime_id, seat_id),

    CONSTRAINT showtime_seats_state_check CHECK (
        (status = 'available' AND held_by_order IS NULL     AND expires_at IS NULL)
     OR (status = 'held'      AND held_by_order IS NOT NULL AND expires_at IS NOT NULL)
     OR (status = 'sold'      AND held_by_order IS NOT NULL AND expires_at IS NULL)
    )
);

CREATE INDEX showtime_seats_order_idx   ON showtime_seats (held_by_order) WHERE held_by_order IS NOT NULL;
CREATE INDEX showtime_seats_expiry_idx  ON showtime_seats (expires_at)    WHERE status = 'held';

CREATE TRIGGER showtime_seats_set_updated_at BEFORE UPDATE ON showtime_seats
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  showtime_seats               IS 'Satu baris per kursi per jadwal, dibuat otomatis saat jadwal dibuat. Klaim kursi = satu UPDATE bersyarat.';
COMMENT ON COLUMN showtime_seats.expires_at    IS 'Tidak dibersihkan siapa pun. Baris yang kedaluwarsa hanya boleh diambil alih oleh pesanan berikutnya.';
COMMENT ON COLUMN showtime_seats.held_by_order IS 'Pemegang kursi. Syarat inilah yang membuat klaim kedua mengembalikan 0 baris.';
COMMENT ON CONSTRAINT showtime_seats_state_check ON showtime_seats IS
    'Menjaga kombinasi status-held_by_order-expires_at tetap masuk akal, sehingga keadaan mustahil tidak bisa tersimpan.';

-- Kursi untuk sebuah jadwal dibuat otomatis, apa pun jalur pembuatannya.
CREATE OR REPLACE FUNCTION generate_showtime_seats() RETURNS trigger AS $$
BEGIN
    INSERT INTO showtime_seats (showtime_id, seat_id)
    SELECT NEW.id, s.id FROM seats s WHERE s.screen_id = NEW.screen_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER showtimes_generate_seats AFTER INSERT ON showtimes
    FOR EACH ROW EXECUTE FUNCTION generate_showtime_seats();

COMMENT ON FUNCTION generate_showtime_seats() IS
    'Menyediakan baris kursi begitu jadwal dibuat - termasuk lewat API CRUD pada Poin C.';

-- 3.3 Tiket -------------------------------------------------------------------
CREATE TABLE tickets (
    id            BIGSERIAL     PRIMARY KEY,
    order_id      BIGINT        NOT NULL REFERENCES orders    (id) ON DELETE RESTRICT,
    showtime_id   BIGINT        NOT NULL REFERENCES showtimes (id) ON DELETE RESTRICT,
    seat_id       BIGINT        NOT NULL REFERENCES seats     (id) ON DELETE RESTRICT,
    price         NUMERIC(12,2) NOT NULL,
    qr_code       TEXT          NOT NULL,
    status        TEXT          NOT NULL DEFAULT 'valid',
    checked_in_at TIMESTAMPTZ,
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT tickets_qr_unique     UNIQUE (qr_code),
    CONSTRAINT tickets_status_check  CHECK (status IN ('valid', 'used', 'refunded')),
    CONSTRAINT tickets_price_check   CHECK (price >= 0)
);

-- Satu kursi hanya boleh punya satu tiket YANG MASIH BERLAKU.
-- Dibuat partial supaya kursi yang sudah direfund boleh dijual ulang.
CREATE UNIQUE INDEX tickets_active_seat_unique
    ON tickets (showtime_id, seat_id) WHERE status = 'valid';

CREATE INDEX tickets_order_idx ON tickets (order_id);

COMMENT ON TABLE tickets IS 'Satu baris = satu kursi = satu kode QR yang discan di pintu.';
COMMENT ON INDEX tickets_active_seat_unique IS
    'Partial unique: syaratnya bersandar pada kolom biasa, jadi sah. Bandingkan dengan predikat now() yang ditolak PostgreSQL.';

-- 3.4 Pembayaran --------------------------------------------------------------
CREATE TABLE payments (
    id                BIGSERIAL     PRIMARY KEY,
    order_id          BIGINT        NOT NULL REFERENCES orders (id) ON DELETE RESTRICT,
    provider          TEXT          NOT NULL,
    payment_reference TEXT          NOT NULL,
    amount            NUMERIC(12,2) NOT NULL,
    status            TEXT          NOT NULL DEFAULT 'pending',
    expires_at        TIMESTAMPTZ   NOT NULL,
    paid_at           TIMESTAMPTZ,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),

    -- Penjaga idempotency webhook: notifikasi yang sama tidak diproses dua kali.
    CONSTRAINT payments_reference_unique UNIQUE (provider, payment_reference),
    CONSTRAINT payments_status_check     CHECK (status IN ('pending', 'paid', 'failed', 'expired')),
    CONSTRAINT payments_amount_check     CHECK (amount >= 0),
    CONSTRAINT payments_paid_at_check    CHECK ((status = 'paid') = (paid_at IS NOT NULL))
);

CREATE INDEX payments_order_idx ON payments (order_id);

COMMENT ON TABLE  payments            IS 'Satu pesanan bisa punya beberapa percobaan pembayaran, misalnya Virtual Account kedaluwarsa lalu pindah ke e-wallet.';
COMMENT ON COLUMN payments.expires_at IS 'Diisi dari orders.expires_at, bukan dihitung ulang, supaya hitung mundur tidak bergeser.';
COMMENT ON CONSTRAINT payments_reference_unique ON payments IS
    'Idempotency notifikasi pembayaran. Notifikasi ulang ditolak database, bukan diingat oleh kode aplikasi.';

-- 3.5 Pengembalian dana -------------------------------------------------------
CREATE TABLE refunds (
    id                BIGSERIAL     PRIMARY KEY,
    payment_id        BIGINT        NOT NULL REFERENCES payments (id) ON DELETE RESTRICT,
    amount            NUMERIC(12,2) NOT NULL,
    reason            TEXT          NOT NULL,
    status            TEXT          NOT NULL DEFAULT 'REQUESTED',
    attempts          INT           NOT NULL DEFAULT 0,
    last_error        TEXT,
    gateway_reference TEXT,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),

    -- Satu pembayaran hanya bisa direfund satu kali.
    CONSTRAINT refunds_payment_unique UNIQUE (payment_id),
    CONSTRAINT refunds_reason_check   CHECK (reason IN ('seat_conflict', 'cinema_cancel', 'user_cancel')),
    CONSTRAINT refunds_status_check   CHECK (status IN ('REQUESTED', 'PROCESSING', 'SUCCEEDED', 'FAILED')),
    CONSTRAINT refunds_amount_check   CHECK (amount >= 0),
    CONSTRAINT refunds_attempts_check CHECK (attempts >= 0)
);

CREATE INDEX refunds_failed_idx ON refunds (created_at) WHERE status = 'FAILED';

COMMENT ON TABLE refunds IS 'Pengembalian dana. Berjalan asinkron dan bisa gagal, karena itu punya status dan penghitung percobaan sendiri.';
COMMENT ON INDEX refunds_failed_idx IS 'Dipakai alert: refund berstatus FAILED berarti ada uang customer yang tersangkut.';


-- =============================================================================
--  4. Pencatatan dan operasional
-- =============================================================================

-- 4.1 Riwayat kursi - hanya boleh ditambah ------------------------------------
CREATE TABLE seat_inventory_ledger (
    id          BIGSERIAL   PRIMARY KEY,
    showtime_id BIGINT      NOT NULL,
    seat_id     BIGINT      NOT NULL,
    from_status TEXT        NOT NULL,
    to_status   TEXT        NOT NULL,
    reason      TEXT        NOT NULL,
    ref_type    TEXT,
    ref_id      BIGINT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ledger_seat_fk FOREIGN KEY (showtime_id, seat_id)
        REFERENCES showtime_seats (showtime_id, seat_id) ON DELETE CASCADE,
    CONSTRAINT ledger_reason_check CHECK (reason IN
        ('user_select', 'hold_expired', 'payment_settled', 'payment_failed',
         'user_cancel', 'cinema_cancel', 'refunded')),
    CONSTRAINT ledger_ref_type_check CHECK (ref_type IS NULL OR ref_type IN ('order', 'payment', 'refund'))
);

CREATE INDEX ledger_seat_idx ON seat_inventory_ledger (showtime_id, seat_id, created_at);
CREATE INDEX ledger_time_idx ON seat_inventory_ledger (created_at);

COMMENT ON TABLE seat_inventory_ledger IS
    'Riwayat perpindahan keadaan kursi. Tidak pernah di-UPDATE atau DELETE: kesalahan dikoreksi dengan baris baru, seperti buku kas.';

-- 4.2 Jejak pembatalan jadwal -------------------------------------------------
CREATE TABLE showtime_cancellations (
    id              BIGSERIAL     PRIMARY KEY,
    showtime_id     BIGINT        NOT NULL REFERENCES showtimes (id) ON DELETE RESTRICT,
    cancelled_by    BIGINT        NOT NULL REFERENCES users     (id) ON DELETE RESTRICT,
    reason          TEXT          NOT NULL,
    affected_orders INT           NOT NULL DEFAULT 0,
    affected_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT cancellations_showtime_unique UNIQUE (showtime_id),
    CONSTRAINT cancellations_reason_check    CHECK (length(btrim(reason)) > 0)
);

COMMENT ON TABLE showtime_cancellations IS
    'Siapa membatalkan, kapan, alasannya, dan berapa besar dampaknya. Ditulis dalam transaksi yang sama dengan pembatalannya.';

-- 4.3 Antrean pekerjaan -------------------------------------------------------
CREATE TABLE jobs (
    id         BIGSERIAL   PRIMARY KEY,
    type       TEXT        NOT NULL,
    payload    JSONB       NOT NULL,
    status     TEXT        NOT NULL DEFAULT 'pending',
    attempts   INT         NOT NULL DEFAULT 0,
    run_after  TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT jobs_type_check     CHECK (type IN ('refund', 'notify_cancellation', 'send_eticket', 'reconcile')),
    CONSTRAINT jobs_status_check   CHECK (status IN ('pending', 'processing', 'done', 'failed')),
    CONSTRAINT jobs_attempts_check CHECK (attempts >= 0)
);

CREATE INDEX jobs_pickup_idx ON jobs (run_after, id) WHERE status = 'pending';
CREATE INDEX jobs_failed_idx ON jobs (created_at)    WHERE status = 'failed';

CREATE TRIGGER jobs_set_updated_at BEFORE UPDATE ON jobs
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE jobs IS
    'Antrean pekerjaan latar belakang. Sengaja tanpa foreign key: sasarannya dirujuk lewat payload, sehingga satu antrean melayani banyak jenis pekerjaan.';
COMMENT ON INDEX jobs_pickup_idx IS
    'Mendukung pengambilan pekerjaan dengan SELECT ... FOR UPDATE SKIP LOCKED.';
