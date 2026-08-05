# Fase 2C — limpeza controlada de temporários de baixo risco

## Objetivo

Preparar uma limpeza limitada e auditável para temporários antigos de baixo risco, sem tocar em ativos técnicos ou na unidade `E:`.

## Seleção autorizada pelo código

Somente arquivos localizados em `UserTemp`, na unidade-alvo, com **mais de 90 dias** e uma destas extensões:

```text
.tmp
.log
.etl
.dmp
```

Arquivos recentes dessas extensões não entram na seleção.

## Proteções permanentes

O script não seleciona outras extensões. Permanecem protegidos, entre outros:

- `.blend` e outros arquivos Blender;
- `.glb` e ativos 3D;
- imagens, vídeos e renders;
- documentos, dados e bancos;
- executáveis, bibliotecas, instaladores e arquivos compactados;
- arquivos sem extensão ou desconhecidos;
- qualquer conteúdo da unidade `E:`.

## Modos

### Preview — padrão

```powershell
powershell.exe -NoProfile -File ".\scripts\maintenance\Invoke-KarvLowRiskTempCleanup.ps1"
```

O modo padrão:

- apenas mede os candidatos;
- não exclui arquivos;
- gera JSON e Markdown sanitizados;
- não registra nomes ou caminhos completos;
- deve ser executado e revisado antes de qualquer autorização de limpeza.

### Apply — bloqueado por guardas explícitas

O modo `Apply` exige simultaneamente:

1. parâmetro `-Mode Apply`;
2. confirmação de que os aplicativos foram fechados;
3. token técnico exato de confirmação.

A existência do modo não representa autorização para executá-lo. O comando de aplicação somente será fornecido depois de autorização explícita do usuário, baseada na prévia local.

## Saída padrão

```text
%LOCALAPPDATA%\KARV\LaptopDiagnostics
```

Os relatórios registram somente:

- contagem e volume candidato por extensão;
- contagem e volume removido, quando autorizado;
- erros por tipo, sem mensagens ou caminhos;
- pontos de nova análise ignorados;
- marcadores de privacidade e exclusão da unidade `E:`.

## Validação

O workflow `Low-risk temp cleanup safety` confirma no Windows PowerShell 5.1 que:

- o modo `Preview` não modifica arquivos;
- `Apply` é rejeitado sem as guardas explícitas;
- a aplicação controlada remove apenas extensões autorizadas e antigas em uma amostra isolada;
- arquivos recentes, `.blend` e `.glb` permanecem intactos;
- nomes e caminhos não aparecem no relatório;
- a unidade `E:` é rejeitada.

## Limite de autorização

A Fase 2C autoriza o desenvolvimento, validação e execução local do modo `Preview`. Nenhuma exclusão local está autorizada antes da apresentação da prévia e de uma confirmação explícita do usuário.

Relacionado à Issue #25.
