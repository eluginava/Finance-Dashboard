-- ═══════════════════════════════════════════════════════════════════════════
-- MUGI POS — skema multi-toko
--
-- CARA PAKAI: buka Supabase → SQL Editor → New query → paste SELURUH file ini
-- (baris 1 sampai habis) → Run. Aman dijalankan berulang kali (idempoten).
--
-- JANGAN menjalankan sebagian file. SQL Editor membungkus seluruh skrip dalam
-- satu transaksi, dan blok-blok di bawah saling bergantung: tabel dibuat dulu,
-- baru diisi. Menjalankan satu blok saja akan gagal dengan pesan seperti
-- "relation stores does not exist" — bukan karena tabelnya hilang, tapi karena
-- pembuatnya ada di bagian atas file yang tidak ikut dijalankan.
--
-- Tabel lama (pos_products, pos_transactions) TIDAK dihapus — tetap jadi
-- cadangan. Secara bawaan isinya juga TIDAK dimigrasi; lihat bagian MIGRASI
-- di bawah kalau suatu saat mau dipindahkan.
--
-- Tidak memerlukan extension apa pun. Hash PIN memakai sha256() bawaan
-- PostgreSQL 11+, bukan digest() dari pgcrypto, supaya tidak bergantung pada
-- search_path project (di Supabase pgcrypto terpasang di schema `extensions`).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. TOKO ────────────────────────────────────────────────────────────────
create table if not exists stores (
  id           text primary key,          -- kode pendek, mis. 'KG'
  name         text not null,
  address      text,
  phone        text,
  receipt_note text default 'Terima kasih!',
  tax_percent  numeric default 10,
  active       boolean default true,
  created_at   timestamptz default now()
);

-- ── 2. USER ────────────────────────────────────────────────────────────────
create table if not exists users (
  id         text primary key,
  username   text unique not null,
  pin_hash   text,                        -- sha256(salt || pin), hex
  pin_salt   text,
  name       text,
  role       text not null default 'kasir',   -- owner | manager | kasir
  -- Kode toko, null = owner (semua toko). SENGAJA tanpa foreign key ke stores:
  -- kode toko diketik bebas oleh Owner lewat tab Pengguna di aplikasi, dan
  -- aplikasi tidak pernah menulis ke tabel stores. FK di sini hanya membuat
  -- sinkron akun kasir/manager ditolak diam-diam.
  store_id   text,
  active     boolean default true,
  auth_uid   uuid,                        -- cadangan upgrade ke Supabase Auth
  created_at timestamptz default now(),
  last_login timestamptz
);

-- ── 3. KATEGORI (2 level: parent_id null = Grup) ───────────────────────────
create table if not exists categories (
  id         bigint primary key,
  parent_id  bigint references categories(id),
  name       text not null,
  emoji      text,
  sort_order int default 0,
  active     boolean default true
);
create unique index if not exists categories_parent_name_idx
  on categories (coalesce(parent_id, 0), name);

-- ── 4. MASTER PRODUK ───────────────────────────────────────────────────────
create table if not exists products (
  id            bigint primary key,
  sku           text,
  name          text not null,
  category_id   bigint references categories(id),
  emoji         text,
  img           text,                     -- data URL
  unit          text,                     -- cup / pcs / set / porsi
  default_price numeric default 0,        -- harga saran, bukan harga jual
  active        boolean default true,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);
create unique index if not exists products_name_idx on products (name);

-- ── 5. VARIAN ──────────────────────────────────────────────────────────────
create table if not exists product_variants (
  id         bigint primary key,
  product_id bigint not null references products(id) on delete cascade,
  name       text default '',             -- '' = varian default (tanpa varian)
  sku        text,
  sort_order int default 0,
  active     boolean default true
);
create index if not exists product_variants_product_idx on product_variants (product_id);

-- ── 6. PRODUK PER TOKO (ketersediaan + harga + stok) ───────────────────────
create table if not exists store_products (
  pkey       text primary key,            -- store_id:product_id:variant_id
  store_id   text not null,
  product_id bigint not null,
  variant_id bigint not null,
  sold       boolean default true,        -- toko ini menjual produk ini?
  price      numeric default 0,           -- harga jual TOKO INI
  stock      numeric default 0,           -- boleh MINUS, hanya penanda
  fav        boolean default false,
  updated_at timestamptz default now()
);
create index if not exists store_products_store_idx on store_products (store_id);
create index if not exists store_products_product_idx on store_products (product_id);

-- ── 7. PELANGGAN / MEMBER (No. HP = primary key, global lintas toko) ───────
create table if not exists customers (
  phone          text primary key,        -- sudah dinormalisasi: 0811...
  name           text,
  visits         int default 0,
  spent          numeric default 0,
  last_visit     timestamptz,
  first_store_id text,
  note           text,
  points         numeric default 0,       -- cadangan program loyalty
  tier           text,                    -- cadangan program loyalty
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);

-- ── 8. SHIFT ───────────────────────────────────────────────────────────────
create table if not exists shifts (
  id            text primary key,
  store_id      text,
  user_id       text,
  cashier_name  text,
  started_at    timestamptz,
  ended_at      timestamptz,
  opening_cash  numeric default 0,
  trx_count     int default 0,
  item_count    int default 0,
  total         numeric default 0,
  cash          numeric default 0,
  qris          numeric default 0,
  card          numeric default 0,
  online        numeric default 0,
  cash_in       numeric default 0,
  cash_out      numeric default 0,
  expected_cash numeric default 0,
  counted_cash  numeric,
  variance      numeric
);
create index if not exists shifts_store_idx on shifts (store_id);

-- ── 9. TRANSAKSI ───────────────────────────────────────────────────────────
create table if not exists transactions (
  uid           text primary key,
  trx_no        text,
  store_id      text,
  user_id       text,
  cashier_name  text,
  shift_id      text,
  created_at    timestamptz,
  device_id     text,
  app_version   text,
  channel       text,
  ref           text,
  cust_phone    text,                     -- tautan ke customers.phone
  cust_name     text,
  voucher       text,
  subtotal      numeric default 0,
  discount      numeric default 0,
  voucher_cut   numeric default 0,
  tax           numeric default 0,
  total         numeric default 0,
  items         jsonb,                    -- [{product_id,variant_id,name,variant_name,unit,price,qty}]
  payments      jsonb,                    -- [{method, amount}]
  method        text,                     -- ringkasan, mis. 'Tunai+QRIS'
  cash_received numeric default 0,
  change        numeric default 0,
  status        text default 'completed', -- completed | void
  voided_at     timestamptz,
  voided_by     text,
  void_reason   text,
  reprint_count int default 0
);
create index if not exists transactions_store_idx  on transactions (store_id);
create index if not exists transactions_time_idx   on transactions (created_at desc);
create index if not exists transactions_phone_idx  on transactions (cust_phone);
create index if not exists transactions_status_idx on transactions (status);

-- ── 10. KAS LACI ───────────────────────────────────────────────────────────
create table if not exists cash_movements (
  id         text primary key,
  shift_id   text,
  store_id   text,
  user_id    text,
  type       text,                        -- in | out
  amount     numeric default 0,
  note       text,
  created_at timestamptz default now()
);
create index if not exists cash_movements_shift_idx on cash_movements (shift_id);

-- ── 11. LOG AKTIVITAS ──────────────────────────────────────────────────────
create table if not exists activity_log (
  id         text primary key,
  store_id   text,
  user_id    text,
  user_name  text,
  action     text,
  entity     text,
  entity_id  text,
  detail     jsonb,
  created_at timestamptz default now()
);
create index if not exists activity_log_time_idx  on activity_log (created_at desc);
create index if not exists activity_log_store_idx on activity_log (store_id);

-- ── 12. VOUCHER ────────────────────────────────────────────────────────────
create table if not exists vouchers (
  code        text primary key,
  type        text default 'percent',     -- percent | amount
  value       numeric default 0,
  active      boolean default true,
  store_id    text,                       -- null = berlaku semua toko
  valid_from  timestamptz,
  valid_until timestamptz
);

-- ═══════════════════════════════════════════════════════════════════════════
-- PERBAIKAN PROJECT YANG SUDAH TERLANJUR DIBUAT
--
-- Bagian ini menyamakan project lama dengan skema di atas. Semuanya memakai
-- "if exists" / "if not exists", jadi aman dijalankan di project baru maupun
-- lama, berulang kali.
-- ═══════════════════════════════════════════════════════════════════════════

-- (a) Lepas foreign key users.store_id kalau project dibuat sebelum catatan
--     di tabel users di atas ditulis.
alter table users drop constraint if exists users_store_id_fkey;

-- (b) Samakan pos_transactions dengan yang dikirim aplikasi.
--
--     PENTING: transaksi masih disinkronkan ke pos_transactions (bukan ke
--     tabel transactions baru). Kalau satu saja kolom di bawah tidak ada,
--     PostgREST menolak SELURUH batch dan penjualan menumpuk di antrean
--     perangkat tanpa pesan error. Daftar ini harus selalu sama dengan
--     trxToRow() di pos.html.
do $$
begin
  if to_regclass('public.pos_transactions') is null then return; end if;

  alter table pos_transactions add column if not exists trx_id      text;
  alter table pos_transactions add column if not exists time        timestamptz;
  alter table pos_transactions add column if not exists channel     text;
  alter table pos_transactions add column if not exists method      text;
  alter table pos_transactions add column if not exists ref         text;
  alter table pos_transactions add column if not exists cashier     text;
  alter table pos_transactions add column if not exists branch      text;
  alter table pos_transactions add column if not exists cust_name   text;
  alter table pos_transactions add column if not exists cust_phone  text;
  alter table pos_transactions add column if not exists voucher     text;
  alter table pos_transactions add column if not exists status      text default 'completed';
  alter table pos_transactions add column if not exists voided_at   timestamptz;
  alter table pos_transactions add column if not exists voided_by   text;
  alter table pos_transactions add column if not exists void_reason text;
  alter table pos_transactions add column if not exists user_id     text;
  alter table pos_transactions add column if not exists shift_id    text;
  alter table pos_transactions add column if not exists device_id   text;
  alter table pos_transactions add column if not exists app_version text;
  alter table pos_transactions add column if not exists payments    jsonb;
  alter table pos_transactions add column if not exists subtotal    numeric;
  alter table pos_transactions add column if not exists discount    numeric;
  alter table pos_transactions add column if not exists tax         numeric;
  alter table pos_transactions add column if not exists total       numeric;
  alter table pos_transactions add column if not exists commission  numeric;
  alter table pos_transactions add column if not exists net         numeric;
  alter table pos_transactions add column if not exists items       jsonb;

  -- Transaksi lama belum punya status; tanpa ini laporan menganggapnya kosong.
  update pos_transactions set status = 'completed' where status is null;

  create index if not exists pos_transactions_branch_idx on pos_transactions (branch);
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- HAK AKSES (RLS)
--
-- CATATAN JUJUR: login MUGI POS berjalan di sisi aplikasi (username + PIN),
-- bukan Supabase Auth. Karena anon key terlihat di halaman publik, policy ini
-- TIDAK mencegah orang teknis membaca data lewat API. Kolom users.auth_uid
-- sudah disiapkan supaya nanti bisa pindah ke Supabase Auth tanpa mengubah
-- struktur tabel.
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare t text;
begin
  foreach t in array array['stores','users','categories','products','product_variants',
                           'store_products','customers','shifts','transactions',
                           'cash_movements','activity_log','vouchers']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists mugi_anon_all on %I', t);
    execute format('create policy mugi_anon_all on %I for all to anon using (true) with check (true)', t);
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- MIGRASI DARI TABEL LAMA  —  MATI SECARA BAWAAN
--
-- Bawaannya tabel baru mulai kosong dan pos_products / pos_transactions
-- dibiarkan utuh sebagai arsip (masih bisa dibaca kapan saja lewat Table
-- Editor). Itu pilihan yang aman: katalog & harga 4 toko diisi dari tab Master
-- di aplikasi, bukan diwarisi dari data satu cabang.
--
-- KALAU SUATU SAAT MAU DIMIGRASI: ubah baris
--     v_migrate boolean := false;
-- menjadi
--     v_migrate boolean := true;
-- lalu jalankan ulang SELURUH file ini. Blok ini idempoten — dijalankan dua
-- kali tidak menggandakan data.
--
-- Blok ini sengaja TIDAK pernah menyebut kolom tabel lama secara langsung.
-- Setiap kolom dibaca lewat to_jsonb(baris) ->> 'nama_kolom', yang menghasilkan
-- NULL kalau kolomnya memang tidak ada — bukan error. Tanpa ini, project yang
-- tabelnya dibuat versi aplikasi lama (belum punya branch / cust_phone /
-- voucher) akan gagal dengan "column ... does not exist", dan karena SQL Editor
-- membungkus semuanya dalam satu transaksi, SELURUH file ikut di-rollback.
-- ═══════════════════════════════════════════════════════════════════════════

-- Normalisasi No. HP: buang selain angka, ubah awalan +62 / 62 jadi 0.
-- Harus sama persis dengan normalizePhone() di pos.html.
create or replace function mugi_norm_phone(p text) returns text as $$
  select case
    when p is null or btrim(p) = '' then null
    else nullif(regexp_replace(regexp_replace(btrim(p), '[^0-9]', '', 'g'), '^62', '0'), '')
  end;
$$ language sql immutable;

do $$
declare
  -- ── SAKELAR MIGRASI ──────────────────────────────────────────────────────
  v_migrate      boolean := false;   -- ubah ke true untuk memigrasi data lama
  v_legacy_store text    := 'LAMA';  -- kode toko penampung baris tanpa cabang
  -- ─────────────────────────────────────────────────────────────────────────
  has_products boolean;
  has_trx      boolean;
  v_grp        bigint;
begin
  if not v_migrate then
    raise notice 'Migrasi data lama dilewati (v_migrate = false).';
    return;
  end if;

  select to_regclass('public.pos_products')     is not null into has_products;
  select to_regclass('public.pos_transactions') is not null into has_trx;

  -- 1) TOKO dari nama cabang yang pernah dipakai. Baris tanpa kolom/isi
  --    cabang ditampung di satu toko bernama v_legacy_store.
  if has_products then
    insert into stores (id, name)
    select b, b from (
      select distinct coalesce(nullif(to_jsonb(pp) ->> 'branch', ''), v_legacy_store) as b
      from pos_products pp
    ) x on conflict (id) do nothing;
  end if;
  if has_trx then
    insert into stores (id, name)
    select b, b from (
      select distinct coalesce(nullif(to_jsonb(t) ->> 'branch', ''), v_legacy_store) as b
      from pos_transactions t
    ) x on conflict (id) do nothing;
  end if;

  if has_products then
    -- 2) KATEGORI: kategori lama jadi anak dari satu Grup sementara "Umum".
    --    Owner merapikan grupnya lewat tab Master setelah migrasi.
    select id into v_grp from categories where parent_id is null and name = 'Umum' limit 1;
    if v_grp is null then
      v_grp := coalesce((select max(id) from categories), 0) + 1;
      insert into categories (id, parent_id, name, sort_order) values (v_grp, null, 'Umum', 0);
    end if;

    insert into categories (id, parent_id, name, sort_order)
    select coalesce((select max(id) from categories), 0) + row_number() over (order by s.c),
           v_grp, s.c, 0
    from (
      select distinct nullif(to_jsonb(pp) ->> 'cat', '') as c from pos_products pp
    ) s
    where s.c is not null
      and not exists (select 1 from categories k where k.parent_id = v_grp and k.name = s.c)
    on conflict do nothing;

    -- 3) MASTER PRODUK: nama sama di beberapa cabang = satu produk master.
    --    Foto/emoji/kategori diambil dari baris pertama yang punya.
    with norm as (
      select nullif(j ->> 'name', '')  as nm,
             nullif(j ->> 'cat', '')   as cat,
             nullif(j ->> 'emoji', '') as emoji,
             nullif(j ->> 'img', '')   as img,
             coalesce(nullif(j ->> 'price', '')::numeric, 0) as price
      from (select to_jsonb(pp) as j from pos_products pp) src
    ), agg as (
      select nm,
             min(cat) as cat,
             (array_agg(emoji) filter (where emoji is not null))[1] as emoji,
             (array_agg(img)   filter (where img   is not null))[1] as img,
             min(price) as price
      from norm where nm is not null group by nm
    )
    insert into products (id, name, category_id, emoji, img, default_price)
    select coalesce((select max(id) from products), 0) + row_number() over (order by a.nm),
           a.nm,
           (select k.id from categories k
             where k.name = a.cat and k.parent_id is not null limit 1),
           a.emoji, a.img, a.price
    from agg a
    where not exists (select 1 from products p where p.name = a.nm)
    on conflict do nothing;

    -- 4) VARIAN default (satu per produk, name = '')
    insert into product_variants (id, product_id, name, sort_order)
    select p.id, p.id, '', 0 from products p
    where not exists (select 1 from product_variants v where v.product_id = p.id)
    on conflict do nothing;

    -- 5) PRODUK PER TOKO: harga & stok lama dibawa apa adanya.
    --    distinct on menjaga satu baris per (toko, produk) supaya upsert tidak
    --    menyentuh baris yang sama dua kali dalam satu perintah.
    with norm as (
      select nullif(j ->> 'name', '') as nm,
             coalesce(nullif(j ->> 'branch', ''), v_legacy_store) as store,
             coalesce(nullif(j ->> 'price', '')::numeric, 0)  as price,
             coalesce(nullif(j ->> 'stock', '')::numeric, 0)  as stock,
             coalesce(nullif(j ->> 'fav', '')::boolean, false) as fav
      from (select to_jsonb(pp) as j from pos_products pp) src
    )
    insert into store_products (pkey, store_id, product_id, variant_id, sold, price, stock, fav)
    select distinct on (n.store, p.id)
           n.store || ':' || p.id || ':' || v.id,
           n.store, p.id, v.id, true, n.price, n.stock, n.fav
    from norm n
    join products p on p.name = n.nm
    join product_variants v on v.product_id = p.id and coalesce(v.name, '') = ''
    where n.nm is not null
    order by n.store, p.id
    on conflict (pkey) do update
      set price = excluded.price, stock = excluded.stock, fav = excluded.fav;
  end if;

  if has_trx then
    -- 6) TRANSAKSI. Kolom yang tidak ada di tabel lama jadi NULL, bukan error.
    insert into transactions (uid, trx_no, store_id, cashier_name, created_at, channel, ref,
                              cust_phone, cust_name, voucher, subtotal, discount, tax, total,
                              items, payments, method, cash_received, change, status)
    select s.j ->> 'uid',
           s.j ->> 'trx_id',
           coalesce(nullif(s.j ->> 'branch', ''), v_legacy_store),
           s.j ->> 'cashier',
           nullif(s.j ->> 'time', '')::timestamptz,
           s.j ->> 'channel',
           s.j ->> 'ref',
           mugi_norm_phone(s.j ->> 'cust_phone'),
           s.j ->> 'cust_name',
           s.j ->> 'voucher',
           coalesce(nullif(s.j ->> 'subtotal', '')::numeric, 0),
           coalesce(nullif(s.j ->> 'discount', '')::numeric, 0),
           coalesce(nullif(s.j ->> 'tax', '')::numeric, 0),
           coalesce(nullif(s.j ->> 'total', '')::numeric, 0),
           s.j -> 'items',
           jsonb_build_array(jsonb_build_object(
             'method', coalesce(s.j ->> 'method', 'Tunai'),
             'amount', coalesce(nullif(s.j ->> 'total', '')::numeric, 0))),
           s.j ->> 'method',
           coalesce(nullif(s.j ->> 'total', '')::numeric, 0),
           0,
           coalesce(nullif(s.j ->> 'status', ''), 'completed')
    from (select to_jsonb(t) as j from pos_transactions t) s
    where nullif(s.j ->> 'uid', '') is not null
    on conflict (uid) do nothing;

    -- 7) Lengkapi item lama dengan product_id / variant_id lewat pencocokan
    --    nama. Yang tidak ketemu dibiarkan null — hanya memengaruhi pemulihan
    --    stok kalau transaksi lama itu di-void.
    update transactions t
    set items = (
      select jsonb_agg(
               case when pr.id is not null
                    then it || jsonb_build_object('product_id', pr.id, 'variant_id', pr.id)
                    else it end
               order by ord)
      from jsonb_array_elements(t.items) with ordinality e(it, ord)
      left join products pr on pr.name = e.it ->> 'name'
    )
    where t.items is not null
      and jsonb_typeof(t.items) = 'array'
      and exists (select 1 from jsonb_array_elements(t.items) x
                   where x ? 'name' and not (x ? 'product_id'));

    -- 8) PELANGGAN: nomor dinormalisasi lebih dulu, lalu baris dengan nomor
    --    yang jadi sama digabung (visits & spent dijumlahkan).
    insert into customers (phone, name, visits, spent, last_visit, first_store_id)
    select ph,
           (array_agg(nm order by tm desc nulls last) filter (where nm is not null))[1],
           count(*), sum(tot), max(tm),
           (array_agg(br order by tm asc nulls last))[1]
    from (
      select mugi_norm_phone(s.j ->> 'cust_phone')                        as ph,
             nullif(s.j ->> 'cust_name', '')                              as nm,
             coalesce(nullif(s.j ->> 'total', '')::numeric, 0)            as tot,
             nullif(s.j ->> 'time', '')::timestamptz                      as tm,
             coalesce(nullif(s.j ->> 'branch', ''), v_legacy_store)       as br
      from (select to_jsonb(t) as j from pos_transactions t) s
      where mugi_norm_phone(s.j ->> 'cust_phone') is not null
    ) c
    group by ph
    on conflict (phone) do update
      set visits     = excluded.visits,
          spent      = excluded.spent,
          last_visit = excluded.last_visit,
          name       = coalesce(excluded.name, customers.name),
          updated_at = now();
  end if;

  raise notice 'Migrasi data lama selesai.';
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- USER AWAL — PIN sementara '1234', WAJIB diganti setelah login pertama.
--
-- Yang pasti terbentuk: satu akun `owner` (akses semua toko). Akun manager &
-- kasir dibuat satu pasang per baris di tabel stores — jadi kalau migrasi mati
-- (bawaan) dan stores masih kosong, HANYA akun owner yang terbentuk. Itu
-- normal: login sebagai owner, lalu tambahkan akun cabang lewat tab Profil →
-- Pengguna → "+ Tambah Akun", isi kode tokonya di sana.
-- ═══════════════════════════════════════════════════════════════════════════
insert into users (id, username, name, role, store_id, pin_salt, pin_hash)
values ('u-owner', 'owner', 'Owner', 'owner', null, 'mugi',
        encode(sha256(convert_to('mugi' || '1234', 'utf8')), 'hex'))
on conflict (username) do nothing;

insert into users (id, username, name, role, store_id, pin_salt, pin_hash)
select 'u-mgr-' || s.id, 'manager-' || regexp_replace(lower(s.id), '[^a-z0-9]+', '', 'g'), 'Manager ' || s.name, 'manager', s.id,
       'mugi', encode(sha256(convert_to('mugi' || '1234', 'utf8')), 'hex')
from stores s
on conflict (username) do nothing;

insert into users (id, username, name, role, store_id, pin_salt, pin_hash)
select 'u-kasir-' || s.id, 'kasir-' || regexp_replace(lower(s.id), '[^a-z0-9]+', '', 'g'), 'Kasir ' || s.name, 'kasir', s.id,
       'mugi', encode(sha256(convert_to('mugi' || '1234', 'utf8')), 'hex')
from stores s
on conflict (username) do nothing;
