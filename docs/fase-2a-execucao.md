# Fase 2A — inventário da unidade C e temporários locais

## Objetivo

Estabelecer uma linha de base somente leitura da unidade `C:` e dos temporários locais antes de qualquer decisão de limpeza.

## Coletor

```text
scripts/diagnostic/Invoke-KarvCTempInventory.ps1
```

O coletor registra somente dados agregados:

- capacidade, uso e espaço livre da unidade analisada;
- quantidade total e volume dos arquivos temporários;
- classificação por idade: 0–7, 8–30, 31–90 e mais de 90 dias;
- classificação por tamanho: abaixo de 1 MB, entre 1 e 100 MB e acima de 100 MB;
- contagem de erros de leitura e pontos de nova análise ignorados.

## Fontes analisadas

- temporários do usuário;
- `Windows Temp`;
- cache local do npm.

Nenhum nome de arquivo, conteúdo ou caminho completo é incluído no relatório.

## Bloqueios permanentes

- A unidade `E:` é rejeitada explicitamente.
- Fontes fora da unidade-alvo são rejeitadas.
- O diretório de saída deve permanecer na unidade-alvo.
- Não há exclusão, movimentação, cópia, compactação ou reparo.
- Não há rede ou transmissão de dados.
- Relatórios reais não podem ser adicionados ao Git.

## Validação antes da execução local

Na pasta `C:\KARV-Laptop`:

```powershell
powershell.exe -NoProfile -File ".\tests\Test-DiagnosticSafety.ps1" -ScriptPath ".\scripts\diagnostic\Invoke-KarvCTempInventory.ps1"
```

A execução local somente deve ocorrer depois de:

1. revisão da Pull Request;
2. aprovação dos checks do GitHub;
3. confirmação de que a branch aprovada foi incorporada à `main`.

## Execução local futura

```powershell
powershell.exe -NoProfile -File ".\scripts\diagnostic\Invoke-KarvCTempInventory.ps1"
```

Saída padrão:

```text
%LOCALAPPDATA%\KARV\LaptopDiagnostics
```

Arquivos gerados:

```text
karv-c-temp-inventory-AAAAmmdd-HHMMSS.json
karv-c-temp-inventory-summary-AAAAmmdd-HHMMSS.md
```

## Limite de autorização

A conclusão desta coleta não autoriza limpeza. O relatório será analisado e uma proposta de remoção será apresentada separadamente, com categorias, impacto e volume estimado. Nenhum arquivo será removido sem autorização explícita.

Relacionado à Issue #18.
