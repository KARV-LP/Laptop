# Fase 3C — inventário somente leitura de tarefas agendadas

## Objetivo

Inventariar tarefas agendadas habilitadas sem executar, interromper, habilitar, desabilitar, registrar, excluir ou alterar qualquer tarefa.

## Componentes

```text
scripts/diagnostic/Invoke-KarvScheduledTaskInventory.ps1
tests/Test-ScheduledTaskInventorySafety.ps1
.github/workflows/scheduled-task-inventory-safety.yml
```

## Escopo autorizado

- leitura de metadados por `Get-ScheduledTask`;
- seleção apenas de tarefas habilitadas;
- metadados de nome, pasta, estado, autor, principal, ações e categorias de gatilho no manifesto local;
- contagens sanitizadas por classificação, estado e categoria de gatilho.

Não são coletados:

- histórico de execução;
- resultados da última execução;
- conteúdo de executáveis ou scripts;
- hashes ou assinaturas;
- dados de rede;
- serviços.

## Contrato de segurança

- modo único `Preview`;
- saída limitada a `%LOCALAPPDATA%\KARV\LaptopDiagnostics`;
- saída obrigatoriamente na unidade `C:`;
- unidade `E:` nunca acessada;
- referências de ações à unidade `E:` redigidas;
- nenhuma tarefa executada ou alterada;
- nenhum arquivo apontado pelas ações é aberto;
- compatibilidade com Windows PowerShell 5.1.

## Classificações

| Classe | Significado | Disposição nesta fase |
|---|---|---|
| `KarvApplicationPreserve` | Tarefa associada a aplicativos conhecidos do ambiente KARV | Preservar |
| `SystemSecurityPreserve` | Tarefa associada ao Windows, Microsoft, segurança ou drivers | Preservar |
| `ThirdPartyReview` | Tarefa habilitada de terceiro ainda não avaliada | Revisão posterior |
| `ExcludedDriveReferencePreserve` | Ação referencia a unidade `E:`; referência redigida | Preservar |
| `UnresolvedPreserve` | Metadado insuficiente ou erro de leitura | Preservar |

Nenhuma classificação significa `SafeToDisable`.

## Categorias de gatilho

O resumo sanitizado apresenta somente contagens agregadas:

- `Boot`;
- `Logon`;
- `Time`;
- `Event`;
- `Idle`;
- `Registration`;
- `SessionStateChange`;
- `Other`.

## Saídas locais

### Manifesto detalhado

```text
karv-scheduled-task-local-manifest-<timestamp>.json
```

Pode conter nomes, autores, contas, ações e caminhos locais. É marcado como sensível, permanece somente no laptop e não deve ser enviado ao GitHub ou ao chat.

### Resumo sanitizado

```text
karv-scheduled-task-sanitized-summary-<timestamp>.json
```

Contém somente totais, classificações, categorias de gatilho, estados, marcadores de privacidade e `SectionFailures`. Não contém nomes, autores, contas, comandos ou caminhos.

## Validação automatizada

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ScheduledTaskInventorySafety.ps1 -ScriptPath .\scripts\diagnostic\Invoke-KarvScheduledTaskInventory.ps1
```

O teste usa dados sintéticos e confirma:

- exclusão de tarefas desabilitadas;
- ausência de comandos de mutação;
- redação de referências simuladas à unidade `E:`;
- resumo sanitizado;
- rejeição de entrada e saída na unidade `E:`;
- criação de dois relatórios locais.

## Execução real após merge

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\diagnostic\Invoke-KarvScheduledTaskInventory.ps1 -Mode Preview
```

## Limite da fase

A Fase 3C termina após o inventário e a avaliação do resumo sanitizado. Nenhuma tarefa será desabilitada ou alterada sem nova análise e autorização explícita.