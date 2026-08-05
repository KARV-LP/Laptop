# Fase 2F — painel local assistido para triagem Blender

## Objetivo

Transformar o manifesto local aprovado da Fase 2E em um relatório HTML estático de triagem, priorizando exclusivamente os maiores itens classificados como `MediumRiskReview`.

Esta fase não relê nem enumera os arquivos `.blend`. O único dado de entrada é o manifesto JSON local criado por `Invoke-KarvBlendAutosaveReview.ps1`.

## Componentes

```text
scripts/diagnostic/Invoke-KarvBlendTriagePanel.ps1
tests/Test-BlendTriagePanelSafety.ps1
.github/workflows/blend-triage-panel-safety.yml
```

Os scripts e resultados das Fases 2D e 2E permanecem inalterados.

## Contrato de segurança

- único modo permitido: `Preview`;
- entrada limitada ao manifesto `karv-blend-autosave-local-manifest-*.json`;
- manifesto e saídas limitados a `%LOCALAPPDATA%\KARV\LaptopDiagnostics` na unidade `C:`;
- unidade `E:` rejeitada explicitamente;
- nenhuma enumeração de `UserTemp`;
- nenhum arquivo `.blend` aberto ou lido;
- nenhum processo Blender iniciado ou encerrado;
- nenhum hash calculado;
- nenhuma rede;
- nenhuma exclusão, movimentação, renomeação, cópia ou alteração de arquivos;
- compatibilidade com Windows PowerShell 5.1.

## Entrada

Quando `-ManifestPath` não é informado, o script seleciona o manifesto local mais recente com o padrão:

```text
karv-blend-autosave-local-manifest-<timestamp>.json
```

O manifesto deve:

- estar dentro da pasta local aprovada;
- declarar `Collector = BlendAutosaveReview`;
- declarar `Mode = Preview`;
- estar marcado como `SensitiveLocalData = true` e `LocalOnly = true`;
- conter apenas caminhos resolvidos na unidade `C:`;
- manter cada item selecionado como `Protected = true`.

## Seleção e prioridade

O painel inclui somente itens com:

```text
RiskClass = MediumRiskReview
```

A ordem é:

1. `LengthBytes` decrescente;
2. `AgeDays` decrescente;
3. `ReviewId` crescente.

Nenhuma classe desta fase significa `SafeToDelete`.

## Saídas locais

A execução cria exatamente dois arquivos em `%LOCALAPPDATA%\KARV\LaptopDiagnostics`.

### HTML local sensível

```text
karv-blend-medium-risk-triage-<timestamp>.html
```

Exibe:

- prioridade;
- `ReviewId`;
- nome;
- caminho local;
- tamanho em MB;
- idade em dias;
- data de modificação UTC;
- estado protegido.

O HTML:

- é estático;
- escapa os campos de texto;
- não contém links, botões, formulários ou JavaScript;
- não abre arquivos;
- não inicia o navegador automaticamente;
- não deve ser enviado ao GitHub, ao chat ou a outra unidade.

### Resumo sanitizado

```text
karv-blend-medium-risk-triage-sanitized-summary-<timestamp>.json
```

Contém somente:

- contagem e volume agregado;
- maior tamanho em MB sem identificação;
- faixas agregadas de tamanho e idade;
- marcadores de privacidade e segurança;
- `SectionFailures`.

Não contém nomes, caminhos, `ReviewId` ou caminho do manifesto.

## Testes automatizados

Os testes usam apenas um manifesto sintético e validam:

- parsing no Windows PowerShell 5.1;
- ausência de comandos destrutivos, rede, hash, processo Blender e enumeração de `UserTemp`;
- rejeição de modo diferente de `Preview`;
- rejeição das unidades `D:` e `E:`;
- rejeição de entrada e saída fora da raiz local aprovada;
- validação da identidade do manifesto da Fase 2E;
- seleção exclusiva de `MediumRiskReview`;
- ordenação por tamanho decrescente;
- escape HTML;
- ausência de ações no painel;
- sanitização do resumo;
- repositório inalterado após os testes.

## Execução real após merge

Na pasta `C:\KARV-Laptop`:

```powershell
git pull --ff-only
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-BlendTriagePanelSafety.ps1 -ScriptPath .\scripts\diagnostic\Invoke-KarvBlendTriagePanel.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\diagnostic\Invoke-KarvBlendTriagePanel.ps1 -Mode Preview
```

O segundo comando detecta automaticamente o manifesto local mais recente da Fase 2E.

Após a execução:

1. confirmar `Status = Passed`;
2. confirmar `SectionFailures = 0`;
3. abrir manualmente apenas o arquivo HTML local;
4. não compartilhar nomes, caminhos, HTML ou manifesto;
5. apresentar ao chat somente os valores agregados do resumo sanitizado;
6. interromper antes de qualquer ação sobre arquivos.

## Limite da fase

Esta fase termina na visualização local da fila priorizada. Abrir, comparar, mover, renomear ou excluir qualquer `.blend` exige nova análise, nova issue e autorização explícita.
