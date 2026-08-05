# Fase 3D — painel local consolidado de revisão de persistência

## Objetivo

Consolidar, em um único HTML local e somente leitura, os itens classificados como `ThirdPartyReview` nos inventários concluídos de inicialização do Windows, serviços automáticos e tarefas agendadas habilitadas.

O painel não decide o que pode ser desabilitado. Ele apenas organiza os dados locais para revisão posterior.

## Componentes

```text
scripts/diagnostic/Invoke-KarvPersistenceTriagePanel.ps1
tests/Test-PersistenceTriagePanelSafety.ps1
.github/workflows/persistence-triage-panel-safety.yml
```

## Entradas

Por padrão, o script autodetecta os manifestos mais recentes dentro de:

```text
%LOCALAPPDATA%\KARV\LaptopDiagnostics
```

Filtros utilizados:

```text
karv-startup-local-manifest-*.json
karv-persistent-services-local-manifest-*.json
karv-scheduled-task-local-manifest-*.json
```

Os manifestos devem ter sido produzidos em `Preview`, estar marcados como `SensitiveLocalData = true` e `LocalOnly = true`, e corresponder aos coletores esperados.

## Seleção

O painel inclui somente registros com:

```text
Classification = ThirdPartyReview
Protected = true
```

Itens preservados por vínculo com KARV, Windows, segurança, drivers, unidade excluída ou metadado insuficiente não aparecem no painel de revisão.

## Saídas

O script cria dois arquivos locais:

```text
karv-persistence-triage-panel-<timestamp>.html
karv-persistence-triage-sanitized-summary-<timestamp>.json
```

O HTML contém dados locais sensíveis, incluindo nomes, contas, comandos e caminhos. Ele não deve ser compartilhado, enviado ao chat ou commitado.

O JSON sanitizado contém somente contagens agregadas.

## Contrato de segurança

- modo único `Preview`;
- compatibilidade com Windows PowerShell 5.1;
- entrada e saída restritas a `%LOCALAPPDATA%\KARV\LaptopDiagnostics` na unidade `C:`;
- unidade `E:` permanentemente excluída;
- referências inesperadas à unidade `E:` são omitidas do painel e contabilizadas apenas de forma agregada;
- nenhuma nova enumeração de Registro, Startup, serviços ou tarefas agendadas;
- nenhuma leitura dos arquivos referenciados;
- nenhum hash, assinatura, rede ou telemetria;
- nenhuma alteração em entradas de inicialização, serviços ou tarefas;
- nenhum botão, link, formulário, JavaScript ou ação no HTML;
- nenhuma abertura automática do navegador;
- nenhuma classificação `SafeToDisable`.

## Execução real

Após sincronizar a `main`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\scripts\diagnostic\Invoke-KarvPersistenceTriagePanel.ps1 `
    -Mode Preview
```

O console exibe somente métricas agregadas. O HTML deve ser aberto manualmente no próprio laptop.

## Interpretação

As três seções do painel são:

1. inicialização do Windows;
2. serviços persistentes;
3. tarefas agendadas.

A presença de um item significa apenas que ele requer revisão. Nenhuma decisão de desativação está autorizada nesta fase.
