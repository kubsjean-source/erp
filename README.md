# ERP 대시보드

Supabase + 정적 HTML 한 페이지로 구성된 운영/영업 통합 대시보드 데모. KPI, 최근 주문, 재고 부족 알림, 신규 문의 등을 단일 화면에서 확인합니다.

## 스택

- **프론트엔드**: 단일 `index.html` (Vanilla JS, Supabase JS Client v2 via CDN)
- **백엔드/DB**: Supabase (Postgres + RLS + Views)
- **배포**: Vercel (정적 호스팅 + SPA rewrites)

## 디렉토리

```
.
├─ index.html      # 대시보드 UI + Supabase 데이터 연동
├─ setup.sql       # 초기 스키마/시드/뷰/RLS 정책
├─ vercel.json     # 정적 호스팅 및 헤더 설정
└─ .env.example    # 환경 변수 템플릿(참고용 — 정적 빌드라 직접 사용되지 않음)
```

## 데이터 모델

| 테이블 | 설명 |
| --- | --- |
| `customers` | 고객 마스터 |
| `products` | 상품 마스터 (SKU, 단가, 안전/현재 재고) |
| `orders` | 주문 헤더 (상태 enum: 결제완료/출고대기/배송중/출고완료/취소) |
| `order_items` | 주문 상세 (`line_total` 자동 계산) |
| `leads` | 신규 문의/리드 (상태 enum: new/contacted/qualified/converted/lost) |
| `kpi_snapshots` | 월별 KPI 스냅샷 |

뷰: `vw_recent_orders`, `vw_low_stock`, `vw_kpi_current` (모두 `security_invoker = true`)

## 셋업

### 1. Supabase 프로젝트 준비

1. [Supabase](https://supabase.com)에서 새 프로젝트 생성
2. SQL Editor → New query → `setup.sql` 전체 붙여넣기 → Run
3. Settings → API에서 다음 두 값 복사
   - Project URL
   - **Publishable key** (`sb_publishable_*`) — RLS 기반 읽기 전용 클라이언트 키

### 2. 클라이언트 키 주입

`index.html` 상단의 다음 두 상수를 본인 프로젝트 값으로 교체:

```js
const SUPABASE_URL = "https://YOUR-PROJECT.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_xxxxx";
```

> **보안 메모**: Publishable(혹은 anon) 키는 클라이언트에 노출되도록 설계된 키입니다. `setup.sql`이 RLS를 켜고 anon에 SELECT만 허용하도록 정책을 두기 때문에 정적 사이트에서 안전하게 사용 가능합니다. **`service_role` 키는 절대 클라이언트 코드에 포함하지 마세요.**

### 3. 로컬에서 보기

별도 빌드가 없으므로 정적 서버로 띄우면 됩니다:

```bash
npx serve .
# 또는
python3 -m http.server 5173
```

브라우저에서 http://localhost:5173 (또는 표시된 포트) 열기.

### 4. Vercel 배포

```bash
vercel
```

`vercel.json`이 SPA rewrite와 보안 헤더를 자동 적용합니다.

## 데이터 갱신

- 시드 데이터를 다시 채우려면 `setup.sql` 하단의 `truncate ... insert ...` 블록만 다시 실행
- KPI는 매월 1일 기준 스냅샷이 `vw_kpi_current`에서 노출됨 (`date_trunc('month', current_date)`)

## RLS 정책

기본 정책: `anon` / `authenticated` 모두에게 **SELECT만 허용**.
쓰기 작업이 필요하면 별도 정책을 추가하거나 서버 사이드(Service Role)에서 수행하세요.
