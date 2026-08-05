# Fase 4A — inventário somente leitura de aplicativos KARV protegidos

## Objetivo

Inventariar aplicações instaladas consideradas parte da ferramenta de trabalho KARV e suas versões registradas localmente, sem executar, atualizar, reparar ou desinstalar qualquer aplicativo.

## Componentes

```text
scripts/diagnostic/Invoke-KarvProtectedApplicationInventory.ps1
tests/Test-ProtectedApplicationInventorySafety.ps1
.github/workflows/protected-application-inventory-safety.yml
```

## Fontes

O coletor abre somente para leitura as chaves de desinstalação do Windows:

```text
HKLM 64 bits
HKLM 32 bits
HKCU 64 bits
HKCU 32 bits
```

Caminho lógico:

```text
SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall
```

Nenhum aplicativo, executável, DLL, atalho ou arquivo instalado é aberto.

## Famílias protegidas

A identificação é conservadora e limitada às seguintes famílias:

```text
Blender
Rhino
Adobe Substance
Canon
GitHub Desktop
Git
Cloudflare / Wrangler
Node.js
Python
```

A ausência de uma família no Registro não prova que o aplicativo não exista. Aplicações portáteis, instalações incompletas ou pacotes não registrados podem não aparecer.

## Dados locais

Para registros protegidos, o manifesto e o HTML locais podem conter:

- nome exibido;
- versão registrada;
- fornecedor;
- data de instalação registrada;
- escopo de usuário ou máquina;
- vista 32 ou 64 bits do Registro;
- local de instalação registrado.

Esses dados são sensíveis e não devem ser enviados ao chat, GitHub ou terceiros.

## Saídas

O script cria três arquivos em:

```text
%LOCALAPPDATA%\KARV\LaptopDiagnostics
```

Arquivos:

```text
karv-protected-applications-local-manifest-<timestamp>.json
karv-protected-applications-sanitized-summary-<timestamp>.json
karv-protected-applications-panel-<timestamp>.html
```

O manifesto e o HTML são locais e sensíveis. O resumo contém somente métricas agregadas.

## Isolamento da unidade E:

A unidade `E:` permanece permanentemente excluída. O coletor não acessa o volume. Se o Registro contiver um caminho que mencione `E:`, os campos de caminho são substituídos por:

```text
[REDACTED_EXCLUDED_DRIVE]
```

A ocorrência é contabilizada somente de forma agregada no resumo sanitizado.

## Contrato de segurança

- modo único `Preview`;
- Windows PowerShell 5.1;
- Registro aberto somente leitura;
- saída limitada à raiz local aprovada na unidade `C:`;
- nenhuma execução de aplicativos ou comandos de versão;
- nenhuma leitura de arquivos instalados;
- nenhum hash ou assinatura;
- nenhuma rede ou telemetria;
- nenhuma consulta de atualização;
- nenhuma alteração de aplicativos, Registro, serviços, tarefas ou inicialização;
- HTML sem JavaScript, links, formulários, botões ou ações;
- nenhuma abertura automática do painel;
- nenhuma autorização de atualização, reparo ou desinstalação.

## Execução real

Após sincronizar a `main`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\scripts\diagnostic\Invoke-KarvProtectedApplicationInventory.ps1 `
    -Mode Preview
```

O console exibe somente métricas agregadas. O painel HTML deve permanecer no laptop.

## Interpretação

- `ProtectedRecords`: registros protegidos encontrados;
- `ProtectedFamiliesExpected`: famílias procuradas;
- `ProtectedFamiliesFound`: famílias com pelo menos um registro;
- `ProtectedFamiliesMissing`: famílias sem registro identificado;
- `FamiliesWithMultipleRecords`: famílias com mais de um registro;
- `UnknownVersionRecords`: registros sem versão informada;
- `ExcludedDriveReferenceRecords`: registros com caminho redigido por referência à unidade `E:`.

Esta fase não compara versões instaladas com versões atuais. A análise de atualização e estabilidade pertence a uma fase posterior e exigirá autorização própria.
