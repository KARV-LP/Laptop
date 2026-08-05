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

## Validação estática

Antes da execução:

```powershell
powershell -NoProfile -File .\tests\Test-DiagnosticSafety.ps1
```

## Execução

```powershell
powershell -NoProfile -File .\scripts\diagnostic\Invoke-KarvReadOnlyDiagnostic.ps1
```

Consulte `docs/fase-1-execucao.md` para o procedimento completo e as regras de compartilhamento.
