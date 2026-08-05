# Fase 2C Apply — limpeza autorizada de temporários de baixo risco

## Autorização

O usuário autorizou explicitamente a exclusão dos arquivos de baixo risco selecionados para liberar espaço na unidade `C:`.

## Arquivos removíveis

O script dedicado seleciona somente arquivos que atendam simultaneamente a estas condições:

- localizados dentro do Temp do usuário atual;
- armazenados na unidade `C:`;
- modificados há mais de 90 dias;
- extensão `.tmp`, `.log` ou `.etl`;
- não são reparse points.

## Arquivos preservados

A autorização não inclui:

- `.dmp`, que permanece como `ReviewThenDelete` e exige autorização separada;
- `.blend` e autosaves do Blender;
- `.glb` e outros ativos 3D;
- imagens, vídeos, renders, documentos e bancos de dados;
- executáveis, bibliotecas, instaladores e arquivos compactados;
- arquivos recentes;
- arquivos sem extensão ou desconhecidos;
- qualquer arquivo fora do Temp do usuário;
- qualquer conteúdo da unidade `E:`.

Nenhuma pasta é removida, mesmo quando fica vazia.

## Script

```text
scripts/maintenance/Invoke-KarvAuthorizedLowRiskTempCleanup.ps1
```

O modo padrão é `Preview`. O modo `Apply` exige simultaneamente:

```text
-Mode Apply
-ApplicationsClosed
-ConfirmationToken KARV-LOW-RISK-CLEANUP-APPLY-AUTHORIZED
```

O script não fecha aplicativos. A declaração `ApplicationsClosed` somente confirma que o usuário salvou o trabalho e encerrou os aplicativos relevantes antes da execução.

## Saídas

Os dois relatórios sanitizados ficam exclusivamente em:

```text
%LOCALAPPDATA%\KARV\LaptopDiagnostics
```

Eles registram apenas:

- quantidade e volume candidato;
- quantidade e volume removido;
- quantidade e volume de dumps preservados;
- falhas de leitura e exclusão por tipo;
- marcadores de privacidade e segurança.

Nomes e caminhos completos não são registrados.

## Contrato de segurança

- unidade `C:` exclusiva;
- unidade `E:` rejeitada antes de qualquer acesso;
- Temp do usuário exclusivo;
- idade mínima de 90 dias;
- nenhuma remoção de diretórios;
- nenhum encerramento de processo;
- nenhuma alteração de serviço, tarefa, Registro, política ou aplicativo;
- nenhuma atualização ou reinicialização;
- nenhuma rede ou telemetria;
- arquivos bloqueados são preservados e contabilizados como falha.

## Execução

A execução real somente deve ocorrer após o merge da PR e com todos os aplicativos de trabalho salvos e fechados.

Relacionado à Issue #49 e à Fase 2C original, Issue #25.
