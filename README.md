# Fichas na Mesa

Controle de **poker cash game** para quando não há fichas físicas suficientes na mesa.

O problema que ele resolve: quando alguém quebra, compra fichas de quem está com o maior
stack. Quem vendeu fica com um **crédito**, quem comprou fica com uma **dívida** somada ao
seu buy-in. No fim da noite, ninguém consegue somar isso de cabeça. O app faz essa conta,
confere se as fichas batem e diz quem paga quem.

## Como usar

É um arquivo só, sem instalação e sem servidor. Abra `index.html` no navegador — no
computador ou no celular. Os dados ficam guardados no próprio aparelho.

Durante o jogo:

- **+ Jogador** — nome, buy-in e de onde vieram as fichas (do estoque ou de outro jogador).
- **Recompra** — quem quebrou, de quem comprou e o valor.
- **⋯ → Sair do jogo** — quanto ele tem em fichas e quem fica com elas.

No fim, **Fechar caixa**: você digita as fichas de cada um e o app confere a contagem,
mostra o resultado de cada jogador e a lista de pagamentos.

## Como a conta funciona

Essa é a parte que vale entender antes de mexer no código.

Toda movimentação de fichas é **um único tipo de evento**: `{de, para, valor}`, onde `null`
significa o estoque de fichas fora da mesa.

| Situação | Evento |
|---|---|
| Buy-in / recompra do estoque | `de: null` → `para: jogador` |
| Recompra comprada de outro jogador | `de: vendedor` → `para: comprador` |
| Jogador sai e vende as fichas | `de: quem sai` → `para: quem compra` |
| Jogador sai e devolve ao estoque | `de: quem sai` → `para: null` |

A partir disso:

- quem **recebe** fichas soma em `investido`
- quem **entrega** fichas soma em `credito`
- `resultado = fichas no fim + credito − investido`
- `fichas na mesa = Σ investido − Σ credito`

Essa última linha é a que valida a contagem final: se a soma das fichas contadas não bate
com ela, alguém contou errado — e o app avisa antes de qualquer um pagar.

O acerto final usa um algoritmo guloso: o maior devedor paga o maior credor, o que dá o
menor número de pagamentos possível.

## O ranking entre sessões

A partida em si continua 100% offline. Só duas coisas falam com a internet:
arquivar a noite e ver o ranking. Sem conexão, o app avisa e a partida segue
normal no celular.

Os dados ficam num Postgres no Supabase (`banco.sql` monta tudo). A chave que
está no `index.html` é pública **de propósito** — num site estático não existe
lugar secreto para guardar chave. Por isso quem decide o que é permitido é o
banco, e não o app:

- **ler** o ranking: liberado para qualquer um;
- **gravar** qualquer coisa: bloqueado por Row Level Security. A única porta de
  entrada são funções `security definer` que exigem a senha do grupo;
- **ler a senha**: a tabela `config` não tem nenhuma policy, então nem o app
  nem ninguém com a chave consegue ler.

Duas proteções valem ser conhecidas antes de mexer:

1. `arquivar_noite` **recusa uma noite cujos resultados não somem zero**. Se a
   contagem das fichas estiver errada, o erro para no banco em vez de entrar no
   ranking de todo mundo.
2. Uma segunda noite na mesma data é recusada, a menos que o app insista. Isso
   evita que quatro pessoas com o link aberto gravem a mesma noite quatro vezes.

O cadastro de jogadores existe porque o ranking soma por pessoa: sem ele,
"Paulo", "paulo" e "Paulinho" seriam três jogadores diferentes. O app sugere
quem já é do grupo, e o banco tem um índice único em `lower(nome)`.

## Mexendo no código

`index.html` tem tudo: HTML, CSS e JavaScript no mesmo arquivo, sem bibliotecas nem build.
Editou, salvou, atualizou a página — pronto.

Três coisas a respeitar:

1. **Não crie tipos separados de transação.** Buy-in, recompra e saída são a mesma operação;
   é isso que mantém a conta correta.
2. **Não use `alert`, `confirm` ou `prompt`.** A página roda dentro de iframes com sandbox
   que bloqueiam essas janelas silenciosamente — o botão simplesmente não faz nada. Use os
   diálogos do próprio app: `confirmar()`, `avisarErro()` e `mostrarTexto()`.
3. **Nada que fale com o banco pode travar a partida.** Toda chamada tem que
   tratar a falha de rede — uma noite de poker sem sinal continua tendo que
   funcionar do começo ao fim.

As cores dos jogadores evitam verde e vermelho de propósito: essas duas ficam reservadas
para lucro e prejuízo.
