# Fase 3B — inventário somente leitura de serviços persistentes

## Objetivo

Inventariar serviços configurados para inicialização automática sem iniciar, parar, desativar, excluir ou alterar qualquer serviço.

## Componentes

```text
scripts/diagnostic/Invoke-KarvPersistentServiceInventory.ps1
tests/Test-PersistentServiceInventorySafety.ps1
.github/workflows/persistent-services-inventory-safety.yml
```

## Escopo autorizado

- leitura de metadados da classe `Win32_Service` via CIM;
- seleção de serviços com `StartMode = Auto`;
- contagem por estado, classificação e categoria de conta;
- manifesto detalhado exclusivamente local;
- resumo sanitizado.

Não são coletados:

- drivers;
- tarefas agendadas;
- conteúdo de executáveis;
- hashes;
- assinaturas digitais;
- dados de rede.

## Contrato de segurança

- modo único `Preview`;
- Windows PowerShell 5.1;
- nenhuma execução de comandos de mutação de serviços;
- nenhum arquivo referenciado por serviço é aberto;
- saída limitada a `%LOCALAPPDATA%\KARV\LaptopDiagnostics` na unidade `C:`;
- unidade `E:` não é acessada;
- caminhos de serviço que mencionem `E:` são descartados antes da gravação;
- serviços permanecem protegidos para revisão posterior.

## Classificações

| Classe | Significado | Disposição |
|---|---|---|
| `KarvApplicationPreserve` | Serviço associado a ferramentas conhecidas do ambiente KARV | Preservar |
| `SystemSecurityPreserve` | Windows, Microsoft, segurança ou drivers de base | Preservar |
| `ThirdPartyReview` | Serviço automático de terceiro ainda não avaliado | Revisão posterior |
| `ExcludedDriveReferencePreserve` | Metadado menciona a unidade `E:`; caminho descartado | Preservar |
| `UnresolvedPreserve` | Metadado insuficiente ou erro de leitura | Preservar |

Nenhuma classe significa `SafeToDisable`.

## Saídas locais

### Manifesto detalhado

```text
karv-persistent-services-local-manifest-<timestamp>.json
```

Pode conter nomes, contas e caminhos locais de serviços, exceto caminhos que façam referência à unidade `E:`, que são descartados. Não deve ser enviado ao GitHub ou ao chat.

### Resumo sanitizado

```text
karv-persistent-services-sanitized-summary-<timestamp>.json
```

Contém somente:

- total de serviços enumerados;
- total de serviços automáticos;
- contagens por classificação;
- contagens por estado;
- categorias agregadas de conta;
- marcadores de privacidade e ausência de mutação;
- falhas por seção.

Não contém nomes, contas ou caminhos.

## Execução após merge

Teste sintético:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-PersistentServiceInventorySafety.ps1 -ScriptPath .\scripts\diagnostic\Invoke-KarvPersistentServiceInventory.ps1
```

Inventário real somente leitura:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\diagnostic\Invoke-KarvPersistentServiceInventory.ps1 -Mode Preview
```

## Limite da fase

A Fase 3B termina após o inventário e a apresentação do resumo sanitizado. Nenhum serviço será alterado sem análise posterior e autorização explícita.