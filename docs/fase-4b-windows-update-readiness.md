# Fase 4B — atualizações do Windows e reinicialização pendente

## Objetivo

Registrar o estado local de manutenção do Windows sem procurar, baixar ou instalar atualizações e sem reiniciar o laptop.

## Componentes

```text
scripts/diagnostic/Invoke-KarvWindowsUpdateReadiness.ps1
tests/Test-WindowsUpdateReadinessSafety.ps1
tests/Test-WindowsUpdateReadinessRuntime.ps1
.github/workflows/windows-update-readiness-safety.yml
```

## Fontes locais

### Metadados do Windows

Leitura somente da chave:

```text
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion
```

Os detalhes de produto, edição, versão e build aparecem somente no manifesto e no painel locais.

### Histórico de atualizações

O coletor utiliza exclusivamente:

```text
Microsoft.Update.Session
CreateUpdateSearcher()
GetTotalHistoryCount()
QueryHistory()
```

O histórico é limitado aos 200 registros locais mais recentes. O script não chama `Search`, não cria downloader ou installer e não consulta atualizações disponíveis.

### Reinicialização pendente

São verificados somente os seguintes indicadores:

1. Component Based Servicing `RebootPending`;
2. Windows Update `RebootRequired`;
3. existência do nome de valor `PendingFileRenameOperations`.

O conteúdo de `PendingFileRenameOperations` não é lido. Portanto, nenhuma lista de caminhos pendentes é coletada.

## Saídas

Todas as saídas permanecem em:

```text
%LOCALAPPDATA%\KARV\LaptopDiagnostics
```

Arquivos gerados:

```text
karv-windows-update-readiness-local-manifest-<timestamp>.json
karv-windows-update-readiness-sanitized-summary-<timestamp>.json
karv-windows-update-readiness-panel-<timestamp>.html
```

O manifesto e o HTML contêm dados locais sensíveis. Não devem ser enviados ao chat, compartilhados ou commitados.

O resumo sanitizado contém apenas:

- quantidade de registros históricos;
- resultados agregados;
- faixas de idade;
- idade da última atualização bem-sucedida e da última falha, quando disponíveis;
- presença e quantidade de indicadores de reinicialização pendente;
- falhas de seção sem detalhes locais.

## Contrato de segurança

- modo único `Preview`;
- Windows PowerShell 5.1;
- Registro aberto somente leitura;
- histórico consultado somente por `QueryHistory`;
- limite de 200 registros;
- nenhuma busca, download ou instalação;
- nenhum `DISM`, `SFC`, `UsoClient`, `wuauclt`, reinício ou desligamento;
- nenhuma leitura de arquivos ou caminhos pendentes;
- nenhuma rede ou telemetria;
- unidade `E:` permanentemente excluída;
- HTML estático, sem links, JavaScript, formulários, botões ou ações;
- nenhuma abertura automática do painel.

## Execução real

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\scripts\diagnostic\Invoke-KarvWindowsUpdateReadiness.ps1 `
    -Mode Preview
```

O resultado `PendingReboot = true` significa apenas que um ou mais indicadores locais estão presentes. Esta fase não autoriza reinicialização.

O resultado `Status = Partial` significa que uma fonte local não pôde ser consultada. Mesmo nesse caso, nenhuma ação de manutenção é executada.
