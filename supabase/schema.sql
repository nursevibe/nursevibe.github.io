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
--    로그인/면허 인증이 아직 없어서 submitted_by는 nullable — 익명 제출을
--    submitter_name/email로 받고, 나중에 계정 시스템이 붙으면 연결한다.
create table services (
  id uuid primary key default gen_random_uuid(),
  submitted_by uuid references profiles(id) on delete set null,
  submitter_name text not null,
  submitter_email text not null,
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
create policy "본인 프로필 생성" on profiles
  for insert with check (auth.uid() = id);
create policy "본인 프로필 수정" on profiles
  for update using (auth.uid() = id);

create policy "본인 인증결과만 조회" on license_verifications
  for select using (auth.uid() = user_id);
-- insert는 서버(service_role, 보건복지부 기관조회 호출부)에서만 수행 — 클라이언트 insert 정책 없음.

create policy "승인된 서비스는 전체 공개" on services
  for select using (status = 'approved' or submitted_by = auth.uid());
create policy "누구나 서비스 제출 가능 (pending으로만)" on services
  for insert with check (status = 'pending');
create policy "admin만 승인/반려 가능" on services
  for update using (
    exists (select 1 from profiles where id = auth.uid() and role = 'admin')
  );

-- 4) FEED 글. services와 같은 패턴 — user_id는 nullable, author_name을 denormalize해서
--    로그인 전/시드 데이터도 표시할 수 있게 한다.
create table posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references profiles(id) on delete set null,
  author_name text not null,
  body text not null,
  tag text check (tag in ('day','evening','night')),
  created_at timestamptz not null default now()
);

alter table posts enable row level security;

create policy "피드는 전체 공개" on posts for select using (true);
create policy "로그인한 본인만 글쓰기" on posts
  for insert with check (auth.uid() = user_id);

-- 5) TOOLBOX 자료함. 큐레이션 콘텐츠라 insert는 운영진이 대시보드(service_role)에서만 한다.
create table files (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text not null,
  ext text not null,
  save_count integer not null default 0,
  created_at timestamptz not null default now()
);

alter table files enable row level security;

create policy "자료함은 전체 공개" on files for select using (true);

-- 6) 부서 카드 활동 인원수 — profiles는 RLS로 본인만 조회 가능하므로, 인원수만
--    집계해서 공개하는 security definer 함수로 우회한다 (개인정보 노출 없음).
create or replace function ward_counts()
returns table(department text, member_count bigint)
language sql security definer set search_path = public as $$
  select department, count(*) from profiles where department is not null group by department;
$$;
grant execute on function ward_counts() to anon, authenticated;

-- 시드 데이터 — 기존 랜딩페이지에 하드코딩돼 있던 문구를 그대로 이식 (화면 변화 없음).
insert into files (name, description, ext, save_count) values
  ('SBAR_인수인계_프롬프트.md', '음성 메모를 SBAR 형식으로 정리하는 프롬프트', 'md', 2104),
  ('NANDA_간호진단_추천_프롬프트.md', '사례를 입력하면 관련 간호진단 후보를 제안', 'md', 1532),
  ('투약계산_공식_시트.xlsx', '드립·희석·소아 용량 계산 공식 모음', 'xlsx', 3318),
  ('식약처_의약품API_연동가이드.md', '실시간 의약품 정보 조회 도구에 붙이는 법', 'md', 861),
  ('신규간호사_온보딩_체크리스트.pdf', '프리셉터십 첫 3개월 점검 항목', 'pdf', 2660);

insert into posts (author_name, body, tag) values
  ('ICU 3년차 올빼미', '방금 만든 투약 드립 계산기 공유해요. 체중·처방 농도만 넣으면 mL/hr 바로 나와요.', 'night'),
  ('외래 새싹', '나이트 끝나고 번아웃 어떻게 푸세요? 다들 본인만의 루틴 있나요.', 'day'),
  ('보건교사 10년', '학생 보호자용 응급처치 안내문, AI로 베트남어·중국어 번역본까지 만들었어요.', 'evening');
