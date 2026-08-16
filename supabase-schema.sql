-- ═══════════════════════════════════════════════════════════════════════════
-- MUGI POS — skema multi-toko
-- Jalankan di Supabase → SQL Editor → Run. Aman dijalankan ulang (idempoten).
--
-- Tabel lama (pos_products, pos_transactions) TIDAK dihapus — tetap jadi
-- cadangan sampai migrasi diverifikasi.
-- ═══════════════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

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
  store_id   text references stores(id),      -- null = owner (semua toko)
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
-- MIGRASI DARI TABEL LAMA
-- Dilewati otomatis kalau pos_products / pos_transactions belum ada.
-- ═══════════════════════════════════════════════════════════════════════════

-- Normalisasi No. HP: buang selain angka, ubah awalan +62 / 62 jadi 0.
create or replace function mugi_norm_phone(p text) returns text as $$
  select case
    when p is null or btrim(p) = '' then null
    else nullif(regexp_replace(regexp_replace(btrim(p), '[^0-9]', '', 'g'), '^62', '0'), '')
  end;
$$ language sql immutable;

do $$
declare
  has_products boolean;
  has_trx      boolean;
begin
  select to_regclass('public.pos_products')     is not null into has_products;
  select to_regclass('public.pos_transactions') is not null into has_trx;

  -- 1) TOKO dari nama cabang yang pernah dipakai
  if has_products then
    insert into stores (id, name)
    select b, b from (
      select distinct coalesce(nullif(branch, ''), 'DEFAULT') as b from pos_products
    ) x on conflict (id) do nothing;
  end if;
  if has_trx then
    insert into stores (id, name)
    select b, b from (
      select distinct coalesce(nullif(branch, ''), 'DEFAULT') as b from pos_transactions
    ) x on conflict (id) do nothing;
  end if;

  if has_products then
    -- 2) KATEGORI: kategori lama jadi anak dari satu Grup sementara "Umum"
    insert into categories (id, parent_id, name, sort_order)
    values (1, null, 'Umum', 0)
    on conflict (coalesce(parent_id, 0), name) do nothing;

    insert into categories (id, parent_id, name, sort_order)
    select 1000 + row_number() over (order by c), 1, c, 0
    from (select distinct nullif(cat, '') as c from pos_products where nullif(cat, '') is not null) s
    on conflict (coalesce(parent_id, 0), name) do nothing;

    -- 3) MASTER PRODUK: nama sama di beberapa cabang = satu produk
    insert into products (id, name, category_id, emoji, img, default_price)
    select min(pp.id),
           pp.name,
           max(c.id),
           max(pp.emoji),
           (array_agg(pp.img) filter (where pp.img is not null))[1],
           min(pp.price)
    from pos_products pp
    left join categories c on c.name = nullif(pp.cat, '') and c.parent_id is not null
    group by pp.name
    on conflict (name) do nothing;

    -- 4) VARIAN default (satu per produk, id = product_id)
    insert into product_variants (id, product_id, name, sort_order)
    select id, id, '', 0 from products
    on conflict (id) do nothing;

    -- 5) PRODUK PER TOKO: harga & stok lama dibawa apa adanya
    insert into store_products (pkey, store_id, product_id, variant_id, sold, price, stock, fav)
    select coalesce(nullif(pp.branch, ''), 'DEFAULT') || ':' || pr.id || ':' || pr.id,
           coalesce(nullif(pp.branch, ''), 'DEFAULT'),
           pr.id, pr.id, true,
           coalesce(pp.price, 0), coalesce(pp.stock, 0), coalesce(pp.fav, false)
    from pos_products pp
    join products pr on pr.name = pp.name
    on conflict (pkey) do update
      set price = excluded.price, stock = excluded.stock, fav = excluded.fav;
  end if;

  if has_trx then
    -- 6) TRANSAKSI
    insert into transactions (uid, trx_no, store_id, cashier_name, created_at, channel, ref,
                              cust_phone, cust_name, voucher, subtotal, discount, tax, total,
                              items, payments, method, cash_received, change, status)
    select t.uid, t.trx_id,
           coalesce(nullif(t.branch, ''), 'DEFAULT'),
           t.cashier, t.time, t.channel, t.ref,
           mugi_norm_phone(t.cust_phone), t.cust_name, t.voucher,
           coalesce(t.subtotal, 0), coalesce(t.discount, 0), coalesce(t.tax, 0), coalesce(t.total, 0),
           t.items,
           jsonb_build_array(jsonb_build_object('method', t.method, 'amount', coalesce(t.total, 0))),
           t.method, coalesce(t.total, 0), 0, 'completed'
    from pos_transactions t
    on conflict (uid) do nothing;

    -- 7) Lengkapi item lama dengan product_id / variant_id lewat pencocokan nama
    update transactions t
    set items = (
      select jsonb_agg(
               case when pr.id is not null
                    then it || jsonb_build_object('product_id', pr.id, 'variant_id', pr.id)
                    else it end
               order by ord)
      from jsonb_array_elements(t.items) with ordinality e(it, ord)
      left join products pr on pr.name = e.it->>'name'
    )
    where t.items is not null
      and jsonb_typeof(t.items) = 'array'
      and not (t.items @> '[{"product_id": null}]'::jsonb)
      and exists (select 1 from jsonb_array_elements(t.items) x where x ? 'name' and not (x ? 'product_id'));

    -- 8) PELANGGAN: dari transaksi, nomor digabung setelah normalisasi
    insert into customers (phone, name, visits, spent, last_visit, first_store_id)
    select ph,
           (array_agg(nm order by tm desc) filter (where nm is not null))[1],
           count(*), sum(tot), max(tm),
           (array_agg(br order by tm asc))[1]
    from (
      select mugi_norm_phone(cust_phone) as ph,
             nullif(cust_name, '')       as nm,
             coalesce(total, 0)          as tot,
             time                        as tm,
             coalesce(nullif(branch, ''), 'DEFAULT') as br
      from pos_transactions
      where mugi_norm_phone(cust_phone) is not null
    ) s
    group by ph
    on conflict (phone) do update
      set visits = excluded.visits,
          spent  = excluded.spent,
          last_visit = excluded.last_visit,
          name = coalesce(excluded.name, customers.name),
          updated_at = now();
  end if;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- USER AWAL — PIN sementara '1234', WAJIB diganti setelah login pertama.
-- Owner: username 'owner'. Tiap toko dapat manager-<kode> dan kasir-<kode>.
-- ═══════════════════════════════════════════════════════════════════════════
insert into users (id, username, name, role, store_id, pin_salt, pin_hash)
values ('u-owner', 'owner', 'Owner', 'owner', null, 'mugi',
        encode(digest('mugi' || '1234', 'sha256'), 'hex'))
on conflict (username) do nothing;

insert into users (id, username, name, role, store_id, pin_salt, pin_hash)
select 'u-mgr-' || s.id, 'manager-' || regexp_replace(lower(s.id), '[^a-z0-9]+', '', 'g'), 'Manager ' || s.name, 'manager', s.id,
       'mugi', encode(digest('mugi' || '1234', 'sha256'), 'hex')
from stores s
on conflict (username) do nothing;

insert into users (id, username, name, role, store_id, pin_salt, pin_hash)
select 'u-kasir-' || s.id, 'kasir-' || regexp_replace(lower(s.id), '[^a-z0-9]+', '', 'g'), 'Kasir ' || s.name, 'kasir', s.id,
       'mugi', encode(digest('mugi' || '1234', 'sha256'), 'hex')
from stores s
on conflict (username) do nothing;
