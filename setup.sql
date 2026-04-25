-- ============================================================
-- ERP 데이터베이스 초기 설정 (Supabase)
-- 실행 방법: Supabase 대시보드 → SQL Editor → New query → 전체 붙여넣기 → Run
-- ============================================================

-- ===== 1. Enum types =====
do $$ begin
  if not exists (select 1 from pg_type where typname = 'order_status') then
    create type public.order_status as enum ('결제완료','출고대기','배송중','출고완료','취소');
  end if;
  if not exists (select 1 from pg_type where typname = 'lead_status') then
    create type public.lead_status as enum ('new','contacted','qualified','converted','lost');
  end if;
end $$;

-- ===== 2. Tables =====
create table if not exists public.customers (
  id          bigserial primary key,
  name        text        not null,
  segment     text,
  email       text,
  phone       text,
  created_at  timestamptz not null default now()
);
create index if not exists idx_customers_name on public.customers (name);

create table if not exists public.products (
  id              bigserial primary key,
  sku             text        unique not null,
  name            text        not null,
  category        text,
  unit            text        not null default 'EA',
  unit_price      integer     not null check (unit_price >= 0),
  safety_stock    integer     not null default 0 check (safety_stock >= 0),
  current_stock   integer     not null default 0 check (current_stock >= 0),
  created_at      timestamptz not null default now()
);
create index if not exists idx_products_category on public.products (category);

create table if not exists public.orders (
  id            bigserial primary key,
  order_no      text                 unique not null,
  customer_id   bigint               not null references public.customers(id) on delete restrict,
  status        public.order_status  not null default '결제완료',
  ordered_at    timestamptz          not null default now(),
  shipped_at    timestamptz,
  note          text
);
create index if not exists idx_orders_customer on public.orders (customer_id);
create index if not exists idx_orders_ordered_at on public.orders (ordered_at desc);
create index if not exists idx_orders_status on public.orders (status);

create table if not exists public.order_items (
  id          bigserial primary key,
  order_id    bigint  not null references public.orders(id) on delete cascade,
  product_id  bigint  not null references public.products(id) on delete restrict,
  quantity    integer not null check (quantity > 0),
  unit_price  integer not null check (unit_price >= 0),
  line_total  bigint  generated always as ((quantity::bigint) * unit_price) stored
);
create index if not exists idx_order_items_order on public.order_items (order_id);
create index if not exists idx_order_items_product on public.order_items (product_id);

create table if not exists public.leads (
  id          bigserial primary key,
  name        text              not null,
  company     text,
  source      text,
  inquiry     text,
  status      public.lead_status not null default 'new',
  created_at  timestamptz       not null default now()
);
create index if not exists idx_leads_status on public.leads (status, created_at desc);

create table if not exists public.kpi_snapshots (
  id            bigserial primary key,
  period        date    not null,
  metric        text    not null,
  label_ko      text    not null,
  value         bigint  not null,
  unit          text    not null,
  delta_pct     numeric(5,1),
  is_progress   boolean not null default false,
  display_order int     not null default 0,
  unique (period, metric)
);
create index if not exists idx_kpi_period on public.kpi_snapshots (period desc);

-- ===== 3. Views (security_invoker = true: 호출자의 RLS 적용) =====
create or replace view public.vw_recent_orders
with (security_invoker = true) as
select
  o.id,
  o.order_no,
  c.name as customer,
  agg.products,
  coalesce(agg.total_amount, 0) as total_amount,
  o.status::text as status,
  to_char(o.ordered_at at time zone 'Asia/Seoul', 'MM-DD') as date_label,
  o.ordered_at
from public.orders o
join public.customers c on c.id = o.customer_id
left join lateral (
  select
    string_agg(p.name, ', ' order by oi.id) as products,
    sum(oi.line_total) as total_amount
  from public.order_items oi
  join public.products p on p.id = oi.product_id
  where oi.order_id = o.id
) agg on true;

create or replace view public.vw_low_stock
with (security_invoker = true) as
select
  p.id,
  p.sku,
  p.name,
  p.current_stock as qty,
  p.safety_stock as safe,
  round((p.current_stock::numeric / nullif(p.safety_stock, 0)) * 100, 1) as fill_pct
from public.products p
where p.current_stock < p.safety_stock;

create or replace view public.vw_kpi_current
with (security_invoker = true) as
select
  k.metric,
  k.label_ko,
  k.value,
  k.unit,
  k.delta_pct,
  k.is_progress,
  k.display_order
from public.kpi_snapshots k
where k.period = date_trunc('month', current_date)::date;

-- ===== 4. RLS (anon 읽기 전용 데모 정책) =====
alter table public.customers      enable row level security;
alter table public.products       enable row level security;
alter table public.orders         enable row level security;
alter table public.order_items    enable row level security;
alter table public.leads          enable row level security;
alter table public.kpi_snapshots  enable row level security;

drop policy if exists "anon_read_customers"     on public.customers;
drop policy if exists "anon_read_products"      on public.products;
drop policy if exists "anon_read_orders"        on public.orders;
drop policy if exists "anon_read_order_items"   on public.order_items;
drop policy if exists "anon_read_leads"         on public.leads;
drop policy if exists "anon_read_kpi_snapshots" on public.kpi_snapshots;

create policy "anon_read_customers"     on public.customers     for select to anon, authenticated using (true);
create policy "anon_read_products"      on public.products      for select to anon, authenticated using (true);
create policy "anon_read_orders"        on public.orders        for select to anon, authenticated using (true);
create policy "anon_read_order_items"   on public.order_items   for select to anon, authenticated using (true);
create policy "anon_read_leads"         on public.leads         for select to anon, authenticated using (true);
create policy "anon_read_kpi_snapshots" on public.kpi_snapshots for select to anon, authenticated using (true);

-- ===== 5. Seed data =====
truncate public.order_items, public.orders, public.leads, public.kpi_snapshots, public.products, public.customers
  restart identity cascade;

-- 고객
insert into public.customers (name, segment, email, phone) values
  ('한빛산업',       '산업체',   'order@hanbit.co.kr',     '02-555-1101'),
  ('그린푸드',       '유통',     'biz@greenfood.kr',       '031-220-3322'),
  ('오로라랩',       '연구개발', 'contact@auroralab.io',   '02-3210-7711'),
  ('정인엔지니어링', '산업체',   'sales@jiengr.co.kr',     '031-880-1100'),
  ('하늘유통',       '유통',     'cs@haneul-dist.kr',      '032-410-2244'),
  ('메이커스튜디오', '스튜디오', 'hi@makerstudio.kr',      '02-6677-5500'),
  ('블루웨이브',     '유통',     'order@bluewave.kr',      '051-330-7788'),
  ('서연테크',       '산업체',   'purchase@seoyeon.tech',  '031-555-9090');

-- 상품
insert into public.products (sku, name, category, unit, unit_price, safety_stock, current_stock) values
  ('SKU-SM-002',  '스마트센서 모듈 v2',     '센서',     'EA',     62000,  80, 18),
  ('SKU-LED-66',  'LED 패널 600x600',       '조명',     'EA',     45000, 120, 42),
  ('SKU-PCB-A',   'PCB 어셈블리 A형',       '전자부품', 'EA',     86000,  50,  7),
  ('SKU-TR-01',   '냉장 트레이',            '포장',     'EA',      9600, 200, 96),
  ('SKU-BX-M',    '포장박스 중형',          '포장',     'EA',       620, 300, 134),
  ('SKU-LED-PNL', 'LED 패널 SET',           '조명',     'SET',  1090000,  30, 45),
  ('SKU-FIL-PLA', '3D 프린팅 필라멘트',     '자재',     'EA',     31200,  40, 78),
  ('SKU-BX-200',  '포장박스 200EA',         '포장',     'SET',    62000,  50, 88);

-- 주문
insert into public.orders (order_no, customer_id, status, ordered_at)
select v.order_no, c.id, v.status::public.order_status, v.ordered_at
from (values
  ('ORD-24102', '한빛산업',         '출고완료', timestamptz '2026-04-24 10:12+09'),
  ('ORD-24101', '그린푸드',         '배송중',   timestamptz '2026-04-24 09:05+09'),
  ('ORD-24100', '오로라랩',         '결제완료', timestamptz '2026-04-23 16:40+09'),
  ('ORD-24099', '정인엔지니어링',   '출고대기', timestamptz '2026-04-23 14:20+09'),
  ('ORD-24098', '하늘유통',         '출고완료', timestamptz '2026-04-22 11:10+09'),
  ('ORD-24097', '메이커스튜디오',   '배송중',   timestamptz '2026-04-22 10:00+09'),
  ('ORD-24096', '블루웨이브',       '출고완료', timestamptz '2026-04-21 15:30+09'),
  ('ORD-24095', '서연테크',         '출고완료', timestamptz '2026-04-20 13:45+09')
) as v(order_no, customer_name, status, ordered_at)
join public.customers c on c.name = v.customer_name;

-- 주문 상세 (단가는 상품 마스터에서 자동 매핑)
insert into public.order_items (order_id, product_id, quantity, unit_price)
select o.id, p.id, v.qty, p.unit_price
from (values
  ('ORD-24102', 'SKU-SM-002',  20),
  ('ORD-24101', 'SKU-TR-01',   50),
  ('ORD-24100', 'SKU-LED-PNL',  2),
  ('ORD-24099', 'SKU-PCB-A',   10),
  ('ORD-24098', 'SKU-BX-200',   2),
  ('ORD-24097', 'SKU-FIL-PLA', 10),
  ('ORD-24096', 'SKU-TR-01',   25),
  ('ORD-24095', 'SKU-LED-66',  12)
) as v(order_no, sku, qty)
join public.orders   o on o.order_no = v.order_no
join public.products p on p.sku = v.sku;

-- 신규문의 (5건 → 사이드바 badge "5"와 매칭)
insert into public.leads (name, company, source, status, inquiry) values
  ('박지훈', '루프트시스템',   '검색',   'new',       '센서 모듈 대량 견적 요청'),
  ('이수연', '코어플랜트',     '광고',   'new',       'LED 패널 설치 문의'),
  ('정민호', '테크니컬허브',   '추천',   'contacted', 'PCB 어셈블리 개발 협업'),
  ('윤가람', '베리타스',       '검색',   'new',       '3D 프린팅 필라멘트 색상'),
  ('한도윤', '시그니처팩',     '전시회', 'qualified', '포장박스 정기 납품');

-- KPI 스냅샷 (현재월: 2026-04, 이전월: 2026-03)
insert into public.kpi_snapshots (period, metric, label_ko, value, unit, delta_pct, is_progress, display_order) values
  ('2026-04-01', 'revenue',        '매출',        128450, '만원',  7.2, false, 1),
  ('2026-04-01', 'shipments',      '출고량',      1842,   '건',    3.4, false, 2),
  ('2026-04-01', 'stock',          '재고',        24310,  'EA',   -2.1, false, 3),
  ('2026-04-01', 'leads',          '신규문의',    137,    '건',   12.5, false, 4),
  ('2026-04-01', 'sales_progress', '영업 진척률', 68,     '%',     4.0, true,  5),
  ('2026-04-01', 'content_views',  '콘텐츠 조회', 92410,  '회',   -1.3, false, 6),
  ('2026-03-01', 'revenue',        '매출',        119822, '만원', null, false, 1),
  ('2026-03-01', 'shipments',      '출고량',      1782,   '건',   null, false, 2),
  ('2026-03-01', 'stock',          '재고',        24832,  'EA',   null, false, 3),
  ('2026-03-01', 'leads',          '신규문의',    122,    '건',   null, false, 4),
  ('2026-03-01', 'sales_progress', '영업 진척률', 65,     '%',    null, true,  5),
  ('2026-03-01', 'content_views',  '콘텐츠 조회', 93628,  '회',   null, false, 6);

-- 검증
select 'customers' as t, count(*) from public.customers
union all select 'products',      count(*) from public.products
union all select 'orders',        count(*) from public.orders
union all select 'order_items',   count(*) from public.order_items
union all select 'leads',         count(*) from public.leads
union all select 'kpi_snapshots', count(*) from public.kpi_snapshots;
