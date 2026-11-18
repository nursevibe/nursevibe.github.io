-- NURSEVIBE — Supabase schema
-- 최소 범위: 로그인/면허 인증 유저 DB + TRY IT branch(서비스 제출) 승인 플로우.
-- 피드/도구함 테이블은 같은 승인 패턴을 재사용하면 되므로 지금은 설계하지 않음.

create type user_role as enum ('member', 'admin');
create type license_type as enum ('RN', 'SN');
create type review_status as enum ('pending', 'approved', 'rejected');

-- 1) auth.users 확장 프로필. Supabase Auth가 이메일/비번/소셜 로그인을 이미 처리하므로
--    이 테이블에는 "앱이 추가로 아는 것"만 둔다.
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  department text, -- 랜딩페이지 DEPT 카드와 동일한 값 (중환자실, 응급실 ...)
  role user_role not null default 'member',
  created_at timestamptz not null default now()
);

-- 2) 면허 인증 결과. 평문 면허번호/주민번호/사진은 절대 저장하지 않는다 — RRN은
--    간편인증(카카오/PASS) 단계에서만 쓰이고 앱 서버로는 넘어오지 않는 전제.
--    license_hash는 중복가입 방지용 단방향 salted hash일 뿐, 역산 불가.
create table license_verifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  license_type license_type not null,
  licensed boolean not null,
  license_hash text not null unique, -- 복호화 불가, 중복계정 방지용
  verification_method text not null, -- 'kakao' | 'pass' | 'telecom' 등 간편인증 수단
  verified_at timestamptz not null default now(),
  expires_at timestamptz
);

-- 3) TRY IT branch — 멤버가 직접 런칭한 서비스(너스mix류)를 올리는 디렉토리.
--    기본 status는 pending, admin이 승인해야 공개 탭에 노출된다.
create table services (
  id uuid primary key default gen_random_uuid(),
  submitted_by uuid not null references profiles(id) on delete cascade,
  name text not null,
  url text not null,
  description text not null,
  department text,
  status review_status not null default 'pending',
  reviewed_by uuid references profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

-- RLS -----------------------------------------------------------------

alter table profiles enable row level security;
alter table license_verifications enable row level security;
alter table services enable row level security;

create policy "본인 프로필 조회/수정" on profiles
  for select using (auth.uid() = id);
create policy "본인 프로필 수정" on profiles
  for update using (auth.uid() = id);

create policy "본인 인증결과만 조회" on license_verifications
  for select using (auth.uid() = user_id);
-- insert는 서버(service_role, 보건복지부 기관조회 호출부)에서만 수행 — 클라이언트 insert 정책 없음.

create policy "승인된 서비스는 전체 공개" on services
  for select using (status = 'approved' or submitted_by = auth.uid());
create policy "로그인 유저는 자기 서비스 제출 가능" on services
  for insert with check (auth.uid() = submitted_by);
create policy "admin만 승인/반려 가능" on services
  for update using (
    exists (select 1 from profiles where id = auth.uid() and role = 'admin')
  );
