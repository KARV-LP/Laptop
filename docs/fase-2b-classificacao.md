# Fase 2B — classificação de temporários antigos e arquivos grandes

## Objetivo

Classificar somente os arquivos de `UserTemp` que atendam a pelo menos um destes critérios:

- idade superior a 90 dias;
- tamanho superior a 100 MB.

O coletor não remove, move, copia, compacta ou altera arquivos.

## Coletor

```text
scripts/diagnostic/Invoke-KarvUserTempClassification.ps1
```

## Dados registrados

Somente informações agregadas:

- quantidade e volume total qualificado;
- interseção entre arquivos antigos e grandes;
- categorias técnicas inferidas pela extensão;
- extensões normalizadas agregadas por volume;
- faixas de idade e tamanho;
- erros de leitura e pontos de nova análise ignorados.

## Categorias

- `TemporaryArtifact`: temporários e logs;
- `RegenerableCache`: caches regeneráveis;
- `DiagnosticDump`: dumps técnicos;
- `InstallerOrArchive`: instaladores e arquivos compactados;
- `TechnicalAsset`: modelos e ativos de produção;
- `RenderOrMedia`: imagens, renders, áudio e vídeo;
- `DocumentOrData`: documentos e dados estruturados;
- `Database`: bancos de dados;
- `ExecutableOrLibrary`: executáveis e bibliotecas;
- `Unknown`: tipo não reconhecido.

A categoria é apenas uma inferência pela extensão. Ela não autoriza exclusão.

## Privacidade e bloqueios

- nenhum nome de arquivo;
- nenhum caminho completo;
- nenhum conteúdo de arquivo;
- nenhum usuário, computador, SID, serial, IP ou MAC;
- nenhuma rede ou transmissão;
- unidade `E:` rejeitada explicitamente;
- saída apenas no disco local autorizado;
- relatórios reais fora do repositório Git.

## Validação

Na pasta `C:\KARV-Laptop`:

```powershell
powershell.exe -NoProfile -File ".\tests\Test-DiagnosticSafety.ps1" `
  -ScriptPath ".\scripts\diagnostic\Invoke-KarvUserTempClassification.ps1"
```

## Execução local futura

Somente após merge da Pull Request e sincronização da `main`:

```powershell
powershell.exe -NoProfile -File ".\scripts\diagnostic\Invoke-KarvUserTempClassification.ps1"
```

Saída padrão:

```text
%LOCALAPPDATA%\KARV\LaptopDiagnostics
```

Arquivos gerados:

```text
karv-user-temp-classification-AAAAmmdd-HHMMSS.json
karv-user-temp-classification-summary-AAAAmmdd-HHMMSS.md
```

## Limite de autorização

A coleta produz uma matriz de risco e recuperabilidade. Nenhum resultado autoriza limpeza automática. Qualquer remoção deve ser proposta separadamente e aprovada explicitamente.

Relacionado à Issue #21.
