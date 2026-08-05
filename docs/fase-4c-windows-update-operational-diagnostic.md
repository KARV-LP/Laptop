# Fase 4C — diagnóstico operacional do Windows Update

## Objetivo

Determinar, em modo somente leitura, qual indicador local mantém o estado de reinicialização pendente e verificar se os componentes essenciais do Windows Update estão presentes e habilitados.

A fase não procura atualizações, não executa reparos e não reinicia o laptop.

## Componentes

```text
scripts/diagnostic/Invoke-KarvWindowsUpdateOperationalDiagnostic.ps1
tests/Test-WindowsUpdateOperationalDiagnosticSafety.ps1
tests/Test-WindowsUpdateOperationalDiagnosticRuntime.ps1
.github/workflows/windows-update-operational-diagnostic-safety.yml
```

## Indicadores de reinicialização

O coletor verifica somente existência:

```text
ComponentBasedServicingRebootPending
WindowsUpdateRebootRequired
PendingFileRenameOperations
```

O conteúdo de `PendingFileRenameOperations` não é lido. A consulta usa apenas os nomes dos valores do Registro.

## Componentes essenciais

São consultados somente nome, estado e modo de inicialização de:

```text
wuauserv
BITS
UsoSvc
TrustedInstaller
CryptSvc
```

Um serviço parado não é classificado automaticamente como defeito. Vários componentes do Windows Update operam sob demanda.

## Eventos locais

O coletor consulta até 200 registros do canal:

```text
Microsoft-Windows-WindowsUpdateClient/Operational
```

Somente estes metadados são coletados:

- ID;
- nível;
- provedor;
- horário UTC.

A mensagem do evento não é lida.

## Classificações

```text
Operational
RebootPendingReview
DegradedReview
InsufficientDataReview
```

Regras:

- `DegradedReview`: componente essencial ausente, desabilitado ou com falha de consulta;
- `InsufficientDataReview`: alguma seção não pôde ser consultada;
- `RebootPendingReview`: componentes sem degradação identificada, mas há indicador de reinicialização;
- `Operational`: nenhum dos casos anteriores.

## Saídas

Todos os arquivos ficam em:

```text
%LOCALAPPDATA%\KARV\LaptopDiagnostics
```

Arquivos gerados:

```text
karv-windows-update-operational-local-manifest-<timestamp>.json
karv-windows-update-operational-sanitized-summary-<timestamp>.json
karv-windows-update-operational-panel-<timestamp>.html
```

O manifesto e o HTML contêm dados locais sensíveis e não devem ser compartilhados.

## Contrato de segurança

- modo único `Preview`;
- Windows PowerShell 5.1;
- Registro, serviços e eventos somente em leitura;
- nenhum conteúdo de valor contendo caminhos é lido;
- nenhuma mensagem de evento é lida;
- nenhuma busca, instalação ou download de atualização;
- nenhum DISM, SFC, reset de componentes ou limpeza de cache;
- nenhum serviço alterado;
- nenhuma reinicialização ou desligamento;
- nenhuma rede ou telemetria;
- unidade `E:` permanentemente excluída;
- HTML estático e sem ações.

## Execução

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\scripts\diagnostic\Invoke-KarvWindowsUpdateOperationalDiagnostic.ps1 `
    -Mode Preview
```

A execução deve ser interrompida após o diagnóstico. Qualquer correção ou reinicialização exige nova autorização explícita.
