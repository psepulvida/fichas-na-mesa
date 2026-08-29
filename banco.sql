-- =====================================================================
--  Fichas na Mesa — estrutura do banco de dados do ranking (Supabase)
--
--  Cole este arquivo inteiro no SQL Editor do Supabase e clique em Run.
--  Pode rodar mais de uma vez sem quebrar nada.
--
--  ANTES DE RODAR: troque TROQUE-ESTA-SENHA, na linha marcada abaixo,
--  pela senha que o grupo vai usar para gravar as partidas.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Tabelas
-- ---------------------------------------------------------------------

-- Os jogadores fixos do grupo. O ranking soma por jogador, então o nome
-- precisa ser único: "Paulo" e "paulo" seriam duas pessoas diferentes.
create table if not exists jogadores (
  id         bigint generated always as identity primary key,
  nome       text not null unique,
  pix        text,
  criado_em  timestamptz not null default now()
);

-- "Paulo" e "paulo" seriam duas linhas diferentes com o unique comum acima,
-- e o ranking apareceria dividido em duas pessoas. Este indice trata as duas
-- grafias como a mesma pessoa.
create unique index if not exists jogadores_nome_unico on jogadores (lower(nome));

-- Cada noite de jogo arquivada.
create table if not exists noites (
  id          bigint generated always as identity primary key,
  data        date not null,
  total_mesa  numeric(12,2) not null default 0,
  criado_em   timestamptz not null default now()
);

-- O resultado de cada jogador naquela noite. Guarda a conta aberta, e não
-- só o saldo, para dar para conferir a noite depois.
create table if not exists resultados (
  id            bigint generated always as identity primary key,
  noite_id      bigint not null references noites(id) on delete cascade,
  jogador_id    bigint not null references jogadores(id) on delete cascade,
  investido     numeric(12,2) not null,
  credito       numeric(12,2) not null,
  fichas_final  numeric(12,2) not null,
  resultado     numeric(12,2) not null,
  unique (noite_id, jogador_id)
);

-- Guarda a senha do grupo. Ninguém consegue ler esta tabela pelo app —
-- só as funções lá embaixo conseguem, para conferir a senha digitada.
create table if not exists config (
  chave  text primary key,
  valor  text not null
);

-- >>> TROQUE A SENHA NA LINHA ABAIXO <<<
insert into config (chave, valor) values ('senha_grupo', 'TROQUE-ESTA-SENHA')
on conflict (chave) do nothing;


-- ---------------------------------------------------------------------
-- 2. Permissões
--
-- A chave do app fica visível no código, que é público. Então o banco
-- precisa ser quem decide o que é permitido, e não o app:
--   - ler o ranking: liberado para todo mundo
--   - gravar qualquer coisa: bloqueado, só através das funções com senha
--   - ler a senha: bloqueado para todos
-- ---------------------------------------------------------------------

alter table jogadores  enable row level security;
alter table noites     enable row level security;
alter table resultados enable row level security;
alter table config     enable row level security;

drop policy if exists "ler jogadores"  on jogadores;
drop policy if exists "ler noites"     on noites;
drop policy if exists "ler resultados" on resultados;

create policy "ler jogadores"  on jogadores  for select using (true);
create policy "ler noites"     on noites     for select using (true);
create policy "ler resultados" on resultados for select using (true);

-- config não ganha nenhuma policy de propósito: sem policy, ninguém acessa.
revoke all on config from anon, authenticated;


-- ---------------------------------------------------------------------
-- 3. Funções que gravam (as únicas portas de entrada)
--
-- "security definer" faz a função rodar com permissão de dono, passando
-- por cima do bloqueio acima — por isso cada uma confere a senha antes.
-- ---------------------------------------------------------------------

create or replace function conferir_senha(p_senha text)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from config where chave = 'senha_grupo' and valor = p_senha
  );
$$;

-- Ninguém chama esta função direto pelo app: ela existe só para as outras.
revoke execute on function conferir_senha(text) from anon, authenticated, public;


-- Cadastra um jogador do grupo, ou atualiza o PIX de quem já existe.
create or replace function salvar_jogador(p_senha text, p_nome text, p_pix text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
begin
  if not conferir_senha(p_senha) then
    raise exception 'SENHA_INVALIDA';
  end if;

  if trim(coalesce(p_nome, '')) = '' then
    raise exception 'NOME_VAZIO';
  end if;

  insert into jogadores (nome, pix)
  values (trim(p_nome), nullif(trim(coalesce(p_pix, '')), ''))
  on conflict (lower(nome)) do update set pix = coalesce(excluded.pix, jogadores.pix)
  returning id into v_id;

  return v_id;
end;
$$;


-- Arquiva uma noite inteira: a noite e o resultado de cada jogador.
-- p_resultados é uma lista no formato:
--   [{"jogador_id":1,"investido":100,"credito":50,"fichas_final":20,"resultado":-30}, ...]
create or replace function arquivar_noite(
  p_senha      text,
  p_data       date,
  p_total      numeric,
  p_resultados jsonb,
  p_forcar     boolean default false
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_noite bigint;
  v_item  jsonb;
  v_soma  numeric := 0;
begin
  if not conferir_senha(p_senha) then
    raise exception 'SENHA_INVALIDA';
  end if;

  if jsonb_array_length(p_resultados) = 0 then
    raise exception 'SEM_RESULTADOS';
  end if;

  -- Evita gravar a mesma noite duas vezes (duas pessoas com o link aberto).
  if not p_forcar and exists (select 1 from noites where data = p_data) then
    raise exception 'NOITE_DUPLICADA';
  end if;

  -- Numa noite fechada corretamente, os resultados somam zero. Se não
  -- somarem, a contagem das fichas estava errada e o ranking herdaria o erro.
  for v_item in select * from jsonb_array_elements(p_resultados) loop
    v_soma := v_soma + (v_item->>'resultado')::numeric;
  end loop;

  if abs(v_soma) > 0.01 then
    raise exception 'NOITE_NAO_FECHA';
  end if;

  insert into noites (data, total_mesa) values (p_data, p_total)
  returning id into v_noite;

  for v_item in select * from jsonb_array_elements(p_resultados) loop
    insert into resultados
      (noite_id, jogador_id, investido, credito, fichas_final, resultado)
    values (
      v_noite,
      (v_item->>'jogador_id')::bigint,
      (v_item->>'investido')::numeric,
      (v_item->>'credito')::numeric,
      (v_item->>'fichas_final')::numeric,
      (v_item->>'resultado')::numeric
    );
  end loop;

  return v_noite;
end;
$$;


-- Apaga uma noite gravada por engano (leva junto os resultados dela).
create or replace function apagar_noite(p_senha text, p_noite_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not conferir_senha(p_senha) then
    raise exception 'SENHA_INVALIDA';
  end if;
  delete from noites where id = p_noite_id;
end;
$$;


-- Tira alguem do cadastro do grupo. Recusa se a pessoa ja tem noites
-- arquivadas, senao o ranking perderia partidas ja jogadas.
create or replace function apagar_jogador(p_senha text, p_jogador_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not conferir_senha(p_senha) then
    raise exception 'SENHA_INVALIDA';
  end if;

  if exists (select 1 from resultados where jogador_id = p_jogador_id) then
    raise exception 'JOGADOR_TEM_NOITES';
  end if;

  delete from jogadores where id = p_jogador_id;
end;
$$;


grant execute on function apagar_jogador(text, bigint)                            to anon, authenticated;
grant execute on function salvar_jogador(text, text, text)                        to anon, authenticated;
grant execute on function arquivar_noite(text, date, numeric, jsonb, boolean)     to anon, authenticated;
grant execute on function apagar_noite(text, bigint)                              to anon, authenticated;


-- ---------------------------------------------------------------------
-- 4. O ranking pronto, para o app só ler e mostrar
-- ---------------------------------------------------------------------

create or replace view ranking as
select
  j.id,
  j.nome,
  j.pix,
  count(r.id)                                      as noites,
  coalesce(sum(r.resultado), 0)                    as saldo,
  coalesce(round(avg(r.resultado), 2), 0)          as media,
  coalesce(max(r.resultado), 0)                    as melhor,
  coalesce(min(r.resultado), 0)                    as pior,
  coalesce(sum(r.investido), 0)                    as total_investido
from jogadores j
left join resultados r on r.jogador_id = j.id
group by j.id, j.nome, j.pix;

grant select on ranking to anon, authenticated;
