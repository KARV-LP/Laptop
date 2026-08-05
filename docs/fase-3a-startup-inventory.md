# Fase 3A — inventário somente leitura da inicialização do Windows

## Objetivo

Inventariar os mecanismos básicos de inicialização do Windows sem alterar, desativar, excluir, mover ou renomear entradas.

## Componente

```text
scripts/diagnostic/Invoke-KarvStartupInventory.ps1
```

Teste:

```text
tests/Test-StartupInventorySafety.ps1
```

Workflow:

```text
.github/workflows/startup-inventory-safety.yml
```

## Escopo autorizado

- Registro do usuário e da máquina: `Run` e `RunOnce`;
- visões de Registro 64-bit e 32-bit;
- pasta Startup do usuário;
- pasta Startup comum;
- geração de manifesto detalhado local;
- geração de resumo sanitizado.

Não são coletados nesta fase:

- serviços;
- tarefas agendadas;
- processos em execução;
- conteúdo interno de executáveis, atalhos ou arquivos;
- hashes;
- dados de rede.

## Contrato de segurança

- modo único `Preview`;
- saída limitada a `%LOCALAPPDATA%\KARV\LaptopDiagnostics`;
- saída obrigatoriamente na unidade `C:`;
- unidade `E:` rejeitada explicitamente;
- chaves do Registro abertas somente para leitura;
- atalhos da pasta Startup não são resolvidos;
- arquivos da pasta Startup não são abertos;
- nenhuma modificação de Registro;
- nenhuma modificação de arquivos;
- nenhum processo iniciado ou encerrado;
- compatibilidade com Windows PowerShell 5.1.

## Classificações

| Classe | Significado | Disposição nesta fase |
|---|---|---|
| `KarvApplicationPreserve` | Entrada associada a aplicativos conhecidos do ambiente KARV | Preservar |
| `SystemSecurityPreserve` | Entrada associada ao Windows, Microsoft, segurança ou drivers | Preservar |
| `ThirdPartyReview` | Entrada de terceiro ainda não avaliada | Revisão posterior |
| `UnresolvedPreserve` | Entrada vazia, incompleta ou com erro de leitura | Preservar |

Nenhuma classe significa `SafeToDisable`.

## Saídas locais

### Manifesto detalhado

```text
karv-startup-local-manifest-<timestamp>.json
```

Pode conter:

- nome da entrada;
- comando ou caminho;
- origem e escopo;
- tipo de valor;
- classificação.

Este arquivo contém dados locais sensíveis e não deve ser enviado ao GitHub ou ao chat.

### Resumo sanitizado

```text
karv-startup-sanitized-summary-<timestamp>.json
```

Contém somente:

- total de entradas;
- contagem por classificação;
- contagem por origem;
- erros por tipo sanitizado;
- `SectionFailures`;
- marcadores de privacidade e ausência de mutação.

Não contém nomes, comandos ou caminhos.

## Execução após merge

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-StartupInventorySafety.ps1 -ScriptPath .\scripts\diagnostic\Invoke-KarvStartupInventory.ps1
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\diagnostic\Invoke-KarvStartupInventory.ps1 -Mode Preview
```

## Limite da fase

A Fase 3A termina após o inventário e a apresentação do resumo sanitizado. Nenhuma entrada será desativada ou alterada sem nova análise e autorização explícita.