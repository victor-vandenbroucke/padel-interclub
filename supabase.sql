-- =====================================================================
-- SwingLab: accounts, statistieken, vrienden, groepen, klassement en uitdagingen
-- Eenmalig uitvoeren in Supabase: SQL Editor > New query > plakken > Run.
-- Je mag het gerust opnieuw uitvoeren: bestaande gegevens blijven behouden.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tabellen ----------

-- Profiel: naam, foto, vriendcode en instellingen (die je op al je toestellen terugkrijgt)
create table if not exists public.profiles (
  id                  uuid primary key references auth.users (id) on delete cascade,
  display_name        text not null default 'Speler' check (char_length(display_name) between 1 and 40),
  avatar_url          text check (avatar_url is null or char_length(avatar_url) < 500),
  friend_code         text not null unique default upper(substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 6)),
  settings            jsonb not null default '{}'::jsonb,
  settings_updated_at timestamptz not null default now(),
  created_at          timestamptz not null default now()
);

-- Statistieken per toestel: elk toestel schrijft alleen zijn eigen rij, de app telt ze op
create table if not exists public.device_stats (
  user_id    uuid not null references auth.users (id) on delete cascade,
  device_id  text not null check (char_length(device_id) between 8 and 64),
  stats      jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, device_id)
);

-- Vrienden: een verzoek (pending) wordt een vriendschap (accepted) zodra de ander het aanvaardt
create table if not exists public.friendships (
  requester  uuid not null references auth.users (id) on delete cascade,
  addressee  uuid not null references auth.users (id) on delete cascade,
  status     text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  primary key (requester, addressee),
  check (requester <> addressee)
);

-- Clubs of groepen, met een code om lid te worden
create table if not exists public.groups (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 1 and 60),
  code       text not null unique default upper(substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 6)),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id  uuid not null references public.groups (id) on delete cascade,
  user_id   uuid not null references auth.users (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

-- Scores van tv-rondes, voor het klassement
create table if not exists public.scores (
  id           bigint generated always as identity primary key,
  user_id      uuid not null default auth.uid() references auth.users (id) on delete cascade,
  sport        text not null check (sport in ('padel', 'tennis', 'pickleball')),
  drill        text not null check (char_length(drill) <= 20),
  level        text not null check (level in ('rustig', 'normaal', 'snel')),
  score        integer not null check (score between 0 and 99999),
  perfect      integer check (perfect between 0 and 50),
  good         integer check (good between 0 and 50),
  miss         integer check (miss between 0 and 50),
  outs         integer check (outs between 0 and 50),
  best_speed   integer check (best_speed between 0 and 300),
  challenge_id uuid,
  created_at   timestamptz not null default now()
);
create index if not exists scores_lookup on public.scores (sport, drill, level, created_at desc);

-- Uitdagingen: allebei een ronde van dezelfde training spelen, de hoogste score wint
create table if not exists public.challenges (
  id               uuid primary key default gen_random_uuid(),
  challenger       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  opponent         uuid not null references auth.users (id) on delete cascade,
  sport            text not null check (sport in ('padel', 'tennis', 'pickleball')),
  drill            text not null check (char_length(drill) <= 20),
  level            text not null check (level in ('rustig', 'normaal', 'snel')),
  challenger_score integer,
  opponent_score   integer,
  status           text not null default 'open' check (status in ('open', 'declined', 'done')),
  created_at       timestamptz not null default now(),
  check (challenger <> opponent)
);

-- ---------- Hulpfuncties (veilig, zonder elkaar eindeloos aan te roepen) ----------

create or replace function public.are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from friendships
    where status = 'accepted'
      and ((requester = a and addressee = b) or (requester = b and addressee = a))
  );
$$;

create or replace function public.share_group(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from group_members m1 join group_members m2 on m1.group_id = m2.group_id
    where m1.user_id = a and m2.user_id = b
  );
$$;

create or replace function public.is_member(g uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from group_members where group_id = g and user_id = auth.uid());
$$;

-- Mag ik deze speler zien? Jezelf, vrienden, groepsgenoten en wie je een vriendschapsverzoek stuurde of kreeg
create or replace function public.can_see(other uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select other = auth.uid()
      or are_friends(auth.uid(), other)
      or share_group(auth.uid(), other)
      or exists (
        select 1 from friendships
        where (requester = auth.uid() and addressee = other)
           or (requester = other and addressee = auth.uid())
      );
$$;

-- Nieuw account: maak meteen een profiel aan
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, display_name)
  values (new.id, left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), 'Speler'), 40))
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Acties die de app oproept ----------

-- Vriend toevoegen met een vriendcode. Had die persoon jou al gevraagd, dan zijn jullie meteen vrienden.
create or replace function public.add_friend(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  them uuid;
  them_name text;
begin
  if me is null then raise exception 'not_logged_in'; end if;
  select id, display_name into them, them_name from profiles where friend_code = upper(trim(p_code));
  if them is null then raise exception 'code_not_found'; end if;
  if them = me then raise exception 'own_code'; end if;
  if exists (select 1 from friendships where requester = them and addressee = me) then
    update friendships set status = 'accepted' where requester = them and addressee = me;
    return them_name;
  end if;
  insert into friendships (requester, addressee) values (me, them) on conflict do nothing;
  return them_name;
end;
$$;

create or replace function public.accept_friend(p_requester uuid) returns void
language sql security definer set search_path = public as $$
  update friendships set status = 'accepted' where requester = p_requester and addressee = auth.uid();
$$;

create or replace function public.remove_friend(p_other uuid) returns void
language sql security definer set search_path = public as $$
  delete from friendships
  where (requester = auth.uid() and addressee = p_other) or (requester = p_other and addressee = auth.uid());
$$;

create or replace function public.create_group(p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare g groups;
begin
  if auth.uid() is null then raise exception 'not_logged_in'; end if;
  insert into groups (name, created_by) values (left(trim(p_name), 60), auth.uid()) returning * into g;
  insert into group_members (group_id, user_id) values (g.id, auth.uid());
  return g.code;
end;
$$;

create or replace function public.join_group(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare g groups;
begin
  if auth.uid() is null then raise exception 'not_logged_in'; end if;
  select * into g from groups where code = upper(trim(p_code));
  if g.id is null then raise exception 'code_not_found'; end if;
  insert into group_members (group_id, user_id) values (g.id, auth.uid()) on conflict do nothing;
  return g.name;
end;
$$;

create or replace function public.leave_group(p_group uuid) returns void
language sql security definer set search_path = public as $$
  delete from group_members where group_id = p_group and user_id = auth.uid();
  delete from groups where id = p_group and not exists (select 1 from group_members where group_id = p_group);
$$;

-- Score bij een uitdaging invullen; de uitdaging is klaar zodra beide spelers gespeeld hebben
create or replace function public.submit_challenge_score(p_challenge uuid, p_score integer) returns challenges
language plpgsql security definer set search_path = public as $$
declare c challenges;
begin
  if p_score < 0 or p_score > 99999 then raise exception 'bad_score'; end if;
  update challenges set
    challenger_score = case when challenger = auth.uid() and challenger_score is null then p_score else challenger_score end,
    opponent_score   = case when opponent   = auth.uid() and opponent_score   is null then p_score else opponent_score end
  where id = p_challenge and status = 'open' and (challenger = auth.uid() or opponent = auth.uid())
  returning * into c;
  if c.id is null then raise exception 'challenge_not_open'; end if;
  if c.challenger_score is not null and c.opponent_score is not null then
    update challenges set status = 'done' where id = c.id returning * into c;
  end if;
  return c;
end;
$$;

create or replace function public.decline_challenge(p_challenge uuid) returns void
language sql security definer set search_path = public as $$
  update challenges set status = 'declined'
  where id = p_challenge and opponent = auth.uid() and status = 'open';
$$;

-- Account en alle gegevens verwijderen (de profielfoto wist de app vooraf zelf)
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'not_logged_in'; end if;
  delete from groups g where g.created_by = auth.uid()
    and not exists (select 1 from group_members m where m.group_id = g.id and m.user_id <> auth.uid());
  delete from auth.users where id = auth.uid();
end;
$$;

-- ---------- Wie mag wat (Row Level Security) ----------

alter table public.profiles      enable row level security;
alter table public.device_stats  enable row level security;
alter table public.friendships   enable row level security;
alter table public.groups        enable row level security;
alter table public.group_members enable row level security;
alter table public.scores        enable row level security;
alter table public.challenges    enable row level security;

drop policy if exists profiles_read   on public.profiles;
drop policy if exists profiles_update on public.profiles;
create policy profiles_read   on public.profiles for select to authenticated using (public.can_see(id));
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists stats_read  on public.device_stats;
drop policy if exists stats_write on public.device_stats;
drop policy if exists stats_change on public.device_stats;
drop policy if exists stats_delete on public.device_stats;
create policy stats_read   on public.device_stats for select to authenticated using (public.can_see(user_id));
create policy stats_write  on public.device_stats for insert to authenticated with check (user_id = auth.uid());
create policy stats_change on public.device_stats for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy stats_delete on public.device_stats for delete to authenticated using (user_id = auth.uid());

drop policy if exists friends_read on public.friendships;
create policy friends_read on public.friendships for select to authenticated using (requester = auth.uid() or addressee = auth.uid());

drop policy if exists groups_read  on public.groups;
drop policy if exists members_read on public.group_members;
create policy groups_read  on public.groups        for select to authenticated using (public.is_member(id));
create policy members_read on public.group_members for select to authenticated using (public.is_member(group_id));

drop policy if exists scores_read   on public.scores;
drop policy if exists scores_insert on public.scores;
drop policy if exists scores_delete on public.scores;
create policy scores_read   on public.scores for select to authenticated using (public.can_see(user_id));
create policy scores_insert on public.scores for insert to authenticated with check (user_id = auth.uid());
create policy scores_delete on public.scores for delete to authenticated using (user_id = auth.uid());

drop policy if exists challenges_read   on public.challenges;
drop policy if exists challenges_insert on public.challenges;
create policy challenges_read   on public.challenges for select to authenticated using (challenger = auth.uid() or opponent = auth.uid());
create policy challenges_insert on public.challenges for insert to authenticated
  with check (challenger = auth.uid() and public.are_friends(auth.uid(), opponent) and challenger_score is null and opponent_score is null and status = 'open');

-- Niet-ingelogde bezoekers mogen niets
revoke all on public.profiles, public.device_stats, public.friendships, public.groups, public.group_members, public.scores, public.challenges from anon;
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.device_stats to authenticated;
grant select on public.friendships, public.groups, public.group_members to authenticated;
grant select, insert, delete on public.scores to authenticated;
grant select, insert on public.challenges to authenticated;

revoke execute on function public.add_friend(text), public.accept_friend(uuid), public.remove_friend(uuid),
  public.create_group(text), public.join_group(text), public.leave_group(uuid),
  public.submit_challenge_score(uuid, integer), public.decline_challenge(uuid), public.delete_my_account() from anon, public;
grant execute on function public.add_friend(text), public.accept_friend(uuid), public.remove_friend(uuid),
  public.create_group(text), public.join_group(text), public.leave_group(uuid),
  public.submit_challenge_score(uuid, integer), public.decline_challenge(uuid), public.delete_my_account() to authenticated;

-- ---------- Profielfoto's ----------

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = true;

drop policy if exists avatars_read   on storage.objects;
drop policy if exists avatars_insert on storage.objects;
drop policy if exists avatars_update on storage.objects;
drop policy if exists avatars_delete on storage.objects;
create policy avatars_read   on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
