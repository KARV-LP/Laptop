# Fase 2D — classificação dos arquivos Blender em UserTemp

## Objetivo

Classificar, em modo estritamente somente leitura, os arquivos `.blend` localizados no `UserTemp` da unidade `C:`. O resultado serve apenas para revisão técnica e decisão posterior.

Esta fase não autoriza exclusão, movimentação, cópia, compactação, renomeação, abertura no Blender, cálculo de hash ou leitura do conteúdo interno dos arquivos.

## Componente

```text
scripts/diagnostic/Invoke-KarvBlendUserTempClassifier.ps1
```

Teste de segurança:

```text
tests/Test-BlendUserTempClassifierSafety.ps1
```

Workflow:

```text
.github/workflows/blend-user-temp-classifier-safety.yml
```

## Contrato de segurança

- único modo permitido: `Preview`;
- origem limitada ao `UserTemp` da unidade `C:`;
- unidade `E:` rejeitada explicitamente;
- qualquer origem ou diretório de saída fora de `C:` é rejeitado;
- nenhuma operação destrutiva;
- nenhum acesso de rede;
- nenhum processo Blender iniciado ou encerrado;
- nenhum nome ou caminho registrado nos relatórios;
- nenhum conteúdo de `.blend` lido;
- nenhum hash calculado;
- erros registrados somente por tipo sanitizado e contagem;
- relatórios reais permanecem exclusivamente no laptop.

## Categorias

| Categoria | Interpretação | Disposição |
|---|---|---|
| `PossibleAutosaveOrRecovery` | Padrão compatível com autosave, recuperação, crash ou sessão | Preservar |
| `PossibleBackupOrVersionCopy` | Padrão compatível com backup, cópia ou versão | Preservar e revisar |
| `PossiblyActiveOrRecentlyModified` | Alteração dentro da janela recente configurada | Preservar |
| `LargeProjectLikeFile` | Tamanho compatível com projeto de trabalho | Preservar |
| `UnclassifiedProtected` | Evidência insuficiente ou atributo especial | Preservar |
| `ReadErrorProtected` | Falha ao obter metadados | Preservar |

As categorias são conservadoras. Nenhuma categoria significa que o arquivo pode ser excluído.

## Possíveis duplicatas

O classificador forma somente grupos candidatos usando:

- tamanho idêntico;
- data de última alteração agrupada por dia;
- mesma classe de padrão técnico.

Limites:

- nenhum hash é calculado;
- nenhum conteúdo é comparado;
- `ConfirmedDuplicates` permanece `0`;
- os grupos não comprovam duplicidade.

## Privacidade da saída

Os relatórios contêm somente:

- contagem e volume total;
- contagem e volume por categoria;
- faixas de idade e tamanho;
- presença booleana de processo Blender;
- quantidade de grupos candidatos;
- erros por tipo sanitizado;
- `SectionFailures`.

Não são incluídos nomes de arquivos, caminhos, nomes de usuário, nome do computador, linha de comando de processos, SID, serial, IP, MAC ou dados da unidade `E:`.

## Validação antes da execução real

A execução no laptop depende de:

1. branch própria;
2. testes sintéticos aprovados no Windows PowerShell 5.1;
3. workflow aprovado no GitHub;
4. Pull Request revisada;
5. merge aprovado na `main`;
6. sincronização local por `git pull --ff-only`;
7. execução inicial somente em `Preview`;
8. validação de `SectionFailures: 0`.

## Comando previsto após o merge

Não executar antes da aprovação da Pull Request.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\diagnostic\Invoke-KarvBlendUserTempClassifier.ps1 -Mode Preview
```

O comando cria um relatório JSON e um resumo Markdown sanitizados em `%LOCALAPPDATA%\KARV\LaptopDiagnostics`.

## Limite da fase

Qualquer proposta futura de hash, comparação adicional, movimentação ou exclusão exige nova Issue e nova autorização explícita.