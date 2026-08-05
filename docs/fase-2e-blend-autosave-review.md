# Fase 2E — revisão controlada dos autosaves Blender antigos

## Objetivo

Revisar, em modo estritamente somente leitura, os arquivos `.blend` de `UserTemp` que apresentam padrão técnico compatível com autosave ou recovery e idade superior a 90 dias.

Esta fase não autoriza exclusão, movimentação, cópia, compactação, renomeação, abertura no Blender, cálculo de hash, leitura do conteúdo interno ou alteração de atributos e timestamps.

## Componente

```text
scripts/diagnostic/Invoke-KarvBlendAutosaveReview.ps1
```

Teste de segurança:

```text
tests/Test-BlendAutosaveReviewSafety.ps1
```

Workflow:

```text
.github/workflows/blend-autosave-review-safety.yml
```

## Contrato de segurança

- único modo permitido: `Preview`;
- origem limitada ao `UserTemp` da unidade `C:`;
- unidade `E:` rejeitada explicitamente;
- qualquer origem fora de `C:` é rejeitada;
- saída limitada a `%LOCALAPPDATA%\KARV\LaptopDiagnostics`;
- nenhuma operação destrutiva;
- nenhum acesso de rede;
- nenhum processo Blender iniciado ou encerrado;
- nenhum arquivo `.blend` aberto ou lido internamente;
- nenhum hash calculado;
- compatibilidade com Windows PowerShell 5.1.

## Seleção

Um item entra na revisão somente quando atende simultaneamente a:

1. extensão `.blend`;
2. nome compatível com `quit`, `autosave`, `auto-save`, `recover`, `recovery`, `crash` ou `session`;
3. idade superior ao limite configurado, com padrão de 90 dias;
4. localização dentro do `UserTemp` resolvido na unidade `C:`.

Arquivos recentes, arquivos comuns sem padrão técnico e diretórios reparse não são incluídos no manifesto.

## Classes de risco

| Classe | Critérios conservadores | Disposição |
|---|---|---|
| `HighRiskPreserve` | processo Blender detectado, atributos especiais, idade entre 91 e 180 dias ou tamanho igual/superior a 500 MB | Preservar |
| `MediumRiskReview` | idade entre 181 e 365 dias ou tamanho igual/superior a 100 MB | Revisão humana |
| `LowerRiskReview` | mais de 365 dias, menos de 100 MB e sem fatores de risco adicionais | Prioridade menor de revisão, ainda protegido |
| `ReadErrorProtected` | falha ao obter metadados | Preservar |

Nenhuma classe significa `SafeToDelete`.

## Saídas locais

A execução cria exatamente dois arquivos em `%LOCALAPPDATA%\KARV\LaptopDiagnostics`.

### Manifesto detalhado local

Nome:

```text
karv-blend-autosave-local-manifest-<timestamp>.json
```

Contém dados sensíveis necessários à revisão humana local:

- nome;
- caminho completo;
- tamanho;
- idade;
- data de modificação;
- atributos;
- classe de risco;
- identificador local de revisão.

O manifesto:

- permanece somente no laptop;
- não deve ser enviado ao GitHub;
- não deve ser colado no chat;
- não deve ser copiado para outra unidade;
- contém aviso explícito de dados locais sensíveis.

### Resumo sanitizado

Nome:

```text
karv-blend-autosave-sanitized-summary-<timestamp>.json
```

Contém somente:

- contagem e volume total;
- contagem e volume por risco;
- faixas agregadas de idade e tamanho;
- presença booleana de processo Blender;
- erros por tipo sanitizado;
- diretórios reparse ignorados;
- `SectionFailures`.

Não contém nomes, caminhos ou identificadores locais.

## Testes automatizados

Os testes usam somente fixtures sintéticas e validam:

- parsing no Windows PowerShell 5.1;
- ausência de comandos destrutivos;
- ausência de rede, hash e leitura de conteúdo;
- rejeição de modo diferente de `Preview`;
- rejeição explícita da unidade `E:`;
- rejeição de origem fora de `C:`;
- rejeição de saída fora da pasta de diagnósticos aprovada;
- seleção somente de autosaves/recoveries antigos;
- classificação conservadora de risco;
- presença de nomes e caminhos somente no manifesto local;
- sanitização do resumo;
- repositório inalterado após os testes.

## Execução real

A execução real depende de:

1. Pull Request aprovada e mergeada;
2. `main` sincronizada por `git pull --ff-only`;
3. teste sintético aprovado localmente;
4. processo Blender preferencialmente fechado;
5. execução somente em `Preview`;
6. `SectionFailures: 0`;
7. apresentação apenas do resumo sanitizado.

Comando previsto após o merge:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\diagnostic\Invoke-KarvBlendAutosaveReview.ps1 -Mode Preview
```

## Limite da fase

Nenhuma exclusão, movimentação ou alteração será proposta ou executada nesta fase. Qualquer futura limpeza exige nova Issue, análise específica e autorização explícita.
