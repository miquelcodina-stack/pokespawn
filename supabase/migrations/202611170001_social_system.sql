-- PokéSpawn Idle v1.0.1 social system
-- Run once in Supabase Dashboard -> SQL Editor -> New query.
create extension if not exists pgcrypto;

create table if not exists public.player_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  friend_code text not null unique,
  trainer_name text not null default 'Trainer' check (char_length(trainer_name) between 1 and 20),
  updated_at timestamptz not null default now()
);
create table if not exists public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  receiver_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (sender_id <> receiver_id),
  unique(sender_id, receiver_id)
);
create table if not exists public.player_friends (
  user_id uuid not null references auth.users(id) on delete cascade,
  friend_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(user_id, friend_id),
  check (user_id <> friend_id)
);
create index if not exists friend_requests_receiver_pending on public.friend_requests(receiver_id,status);
create index if not exists friend_requests_sender_pending on public.friend_requests(sender_id,status);
alter table public.player_profiles enable row level security;
alter table public.friend_requests enable row level security;
alter table public.player_friends enable row level security;

drop policy if exists "profiles are readable by authenticated players" on public.player_profiles;
create policy "players can read their own profile" on public.player_profiles for select to authenticated using (auth.uid() = user_id);
drop policy if exists "players can read their own friend requests" on public.friend_requests;
create policy "players can read their own friend requests" on public.friend_requests for select to authenticated using (auth.uid() = sender_id or auth.uid() = receiver_id);
drop policy if exists "players can read their friendships" on public.player_friends;
create policy "players can read their friendships" on public.player_friends for select to authenticated using (auth.uid() = user_id);

create or replace function public.pz_register_profile(p_friend_code text, p_trainer_name text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_user uuid := auth.uid(); v_code text := upper(trim(p_friend_code)); v_name text := left(trim(regexp_replace(coalesce(p_trainer_name,'Trainer'), '\s+', ' ', 'g')),20); v_row public.player_profiles;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 if v_code !~ '^PZ-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$' then raise exception 'Invalid Friend Code'; end if;
 if v_name = '' then v_name := 'Trainer'; end if;
 insert into public.player_profiles(user_id,friend_code,trainer_name) values(v_user,v_code,v_name)
 on conflict(user_id) do update set trainer_name=excluded.trainer_name,updated_at=now()
 returning * into v_row;
 return jsonb_build_object('friend_code',v_row.friend_code,'trainer_name',v_row.trainer_name);
end $$;

create or replace function public.pz_get_social_data()
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_user uuid := auth.uid(); v_profile jsonb; v_friends jsonb; v_incoming jsonb; v_outgoing jsonb;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select to_jsonb(p) into v_profile from public.player_profiles p where p.user_id=v_user;
 select coalesce(jsonb_agg(jsonb_build_object('user_id',p.user_id,'friend_code',p.friend_code,'trainer_name',p.trainer_name) order by p.trainer_name),'[]'::jsonb) into v_friends
 from public.player_friends f join public.player_profiles p on p.user_id=f.friend_id where f.user_id=v_user;
 select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'user_id',p.user_id,'friend_code',p.friend_code,'trainer_name',p.trainer_name,'created_at',r.created_at) order by r.created_at),'[]'::jsonb) into v_incoming
 from public.friend_requests r join public.player_profiles p on p.user_id=r.sender_id where r.receiver_id=v_user and r.status='pending';
 select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'user_id',p.user_id,'friend_code',p.friend_code,'trainer_name',p.trainer_name,'created_at',r.created_at) order by r.created_at),'[]'::jsonb) into v_outgoing
 from public.friend_requests r join public.player_profiles p on p.user_id=r.receiver_id where r.sender_id=v_user and r.status='pending';
 return jsonb_build_object('profile',v_profile,'friends',v_friends,'incoming',v_incoming,'outgoing',v_outgoing);
end $$;

create or replace function public.pz_find_player(p_friend_code text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_user uuid := auth.uid(); v_row public.player_profiles;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select * into v_row from public.player_profiles where friend_code=upper(trim(p_friend_code)) and user_id<>v_user;
 if not found then return null; end if;
 return jsonb_build_object('friend_code',v_row.friend_code,'trainer_name',v_row.trainer_name);
end $$;

create or replace function public.pz_send_friend_request(p_friend_code text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_user uuid := auth.uid(); v_target public.player_profiles; v_reverse public.friend_requests; v_request public.friend_requests;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select * into v_target from public.player_profiles where friend_code=upper(trim(p_friend_code));
 if not found then raise exception 'Friend Code not found'; end if;
 if v_target.user_id=v_user then raise exception 'That is your own Friend Code'; end if;
 if exists(select 1 from public.player_friends where user_id=v_user and friend_id=v_target.user_id) then raise exception 'Already friends'; end if;
 select * into v_reverse from public.friend_requests where sender_id=v_target.user_id and receiver_id=v_user and status='pending' for update;
 if found then
  update public.friend_requests set status='accepted',updated_at=now() where id=v_reverse.id;
  insert into public.player_friends(user_id,friend_id) values(v_user,v_target.user_id),(v_target.user_id,v_user) on conflict do nothing;
  return jsonb_build_object('status','accepted','trainer_name',v_target.trainer_name);
 end if;
 insert into public.friend_requests(sender_id,receiver_id) values(v_user,v_target.user_id)
 on conflict(sender_id,receiver_id) do update set status='pending',updated_at=now() returning * into v_request;
 return jsonb_build_object('status','pending','trainer_name',v_target.trainer_name);
end $$;

create or replace function public.pz_respond_friend_request(p_request_id uuid,p_accept boolean)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_user uuid := auth.uid(); v_request public.friend_requests;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select * into v_request from public.friend_requests where id=p_request_id and receiver_id=v_user and status='pending' for update;
 if not found then raise exception 'Friend request not found'; end if;
 update public.friend_requests set status=case when p_accept then 'accepted' else 'declined' end,updated_at=now() where id=p_request_id;
 if p_accept then
  insert into public.player_friends(user_id,friend_id) values(v_user,v_request.sender_id),(v_request.sender_id,v_user) on conflict do nothing;
 end if;
end $$;

create or replace function public.pz_remove_friend(p_friend_id uuid)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_user uuid := auth.uid();
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 delete from public.player_friends where (user_id=v_user and friend_id=p_friend_id) or (user_id=p_friend_id and friend_id=v_user);
 delete from public.friend_requests where (sender_id=v_user and receiver_id=p_friend_id) or (sender_id=p_friend_id and receiver_id=v_user);
end $$;

revoke all on function public.pz_register_profile(text,text) from public;
revoke all on function public.pz_get_social_data() from public;
revoke all on function public.pz_find_player(text) from public;
revoke all on function public.pz_send_friend_request(text) from public;
revoke all on function public.pz_respond_friend_request(uuid,boolean) from public;
revoke all on function public.pz_remove_friend(uuid) from public;
grant execute on function public.pz_register_profile(text,text) to authenticated;
grant execute on function public.pz_get_social_data() to authenticated;
grant execute on function public.pz_find_player(text) to authenticated;
grant execute on function public.pz_send_friend_request(text) to authenticated;
grant execute on function public.pz_respond_friend_request(uuid,boolean) to authenticated;
grant execute on function public.pz_remove_friend(uuid) to authenticated;
