# Scripts de diagnóstico

Esta pasta contém rotinas somente leitura para inventário e diagnóstico do laptop KARV.

## Implementação atual

### `Invoke-KarvReadOnlyDiagnostic.ps1`

Gera uma linha de base sanitizada do Windows, hardware, armazenamento, processos, inicialização, drivers, aplicativos, eventos, caches técnicos e segurança básica.

Garantias de projeto:

- não altera configurações;
- não instala dependências;
- não transmite dados;
- não coleta nome do computador, usuário, serial, UUID, MAC, IP ou mensagens completas de eventos;
- salva resultados somente em destino local fora de repositórios Git;
- cria JSON detalhado e resumo Markdown;
- permite ignorar a leitura de caches com `-SkipCacheScan`.

### `Invoke-KarvStorageSecurityDiagnostic.ps1`

Executa a investigação direcionada e somente leitura de armazenamento e proteção antimalware usada na Fase 1.

### `Invoke-KarvCTempInventory.ps1`

Mede a unidade local autorizada e classifica temporários do usuário, `Windows Temp` e cache do npm por idade e tamanho.

Garantias específicas:

- unidade `C:` como alvo padrão;
- unidade `E:` rejeitada permanentemente;
- fontes e saída restritas à unidade-alvo;
- pontos de nova análise ignorados;
- nenhum nome, conteúdo ou caminho completo de arquivo no relatório;
- nenhuma exclusão, movimentação, cópia, reparo ou transmissão;
- saída agregada em JSON e Markdown.

## Validação estática

Antes da execução do diagnóstico-base:

```powershell
powershell -NoProfile -File .\tests\Test-DiagnosticSafety.ps1
```

Antes da execução do inventário de temporários:

```powershell
powershell.exe -NoProfile -File ".\tests\Test-DiagnosticSafety.ps1" -ScriptPath ".\scripts\diagnostic\Invoke-KarvCTempInventory.ps1"
```

## Execução

Diagnóstico-base:

```powershell
powershell -NoProfile -File .\scripts\diagnostic\Invoke-KarvReadOnlyDiagnostic.ps1
```

Inventário da unidade `C:` e temporários:

```powershell
powershell.exe -NoProfile -File ".\scripts\diagnostic\Invoke-KarvCTempInventory.ps1"
```

Consulte `docs/fase-1-execucao.md` e `docs/fase-2a-execucao.md` para os procedimentos completos e as regras de compartilhamento.
