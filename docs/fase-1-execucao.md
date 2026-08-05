# Fase 1 — execução do diagnóstico somente leitura

## Objetivo

Gerar uma linha de base técnica do laptop sem alterar o Windows, instalar dependências, limpar arquivos ou transmitir dados.

## O que o script consulta

- fabricante e modelo do equipamento;
- Windows, build, arquitetura e uptime;
- CPU, memória e GPU;
- volumes locais, discos físicos e indicadores de saúde disponíveis;
- processos com maior CPU acumulada;
- itens de inicialização;
- drivers de vídeo, rede, armazenamento, sistema e mídia;
- aplicativos registrados no Windows;
- resumo agregado de eventos críticos e erros dos últimos sete dias;
- hotfixes recentes e estado básico do Microsoft Defender;
- bateria, quando disponível;
- tamanho agregado de caches técnicos selecionados.

## Dados deliberadamente excluídos

O relatório não deve conter:

- nome do computador ou usuário;
- serial, UUID, service tag ou identificadores de dispositivo;
- MAC, endereço IP ou redes Wi-Fi;
- mensagens completas dos eventos do Windows;
- comandos de inicialização;
- caminhos completos do perfil;
- chaves de licença, tokens, cookies ou credenciais;
- nomes dos arquivos encontrados nos caches.

## Efeito local permitido

O único efeito de escrita é a criação de dois relatórios locais em:

```text
%LOCALAPPDATA%\KARV\LaptopDiagnostics
```

Arquivos gerados:

```text
karv-laptop-diagnostic-AAAAMMDD-HHMMSS.json
karv-laptop-summary-AAAAMMDD-HHMMSS.md
```

O script bloqueia diretórios de saída que estejam dentro de um repositório Git.

## Validação antes da execução

Na raiz do repositório, execute:

```powershell
powershell -NoProfile -File .\tests\Test-DiagnosticSafety.ps1
```

Resultado esperado:

```text
Status         : Passed
ForbiddenFound : 0
NetworkFound   : 0
```

## Execução padrão

```powershell
powershell -NoProfile -File .\scripts\diagnostic\Invoke-KarvReadOnlyDiagnostic.ps1
```

A varredura dos caches pode gerar leitura intensa de disco por alguns minutos, mas não remove ou modifica arquivos.

Para executar sem medir caches:

```powershell
powershell -NoProfile -File .\scripts\diagnostic\Invoke-KarvReadOnlyDiagnostic.ps1 -SkipCacheScan
```

## Resultado esperado

```text
Status          : Complete
OutputDirectory : %LOCALAPPDATA%\KARV\LaptopDiagnostics
SectionFailures : 0
```

Algumas seções podem aparecer como indisponíveis quando o hardware, o driver ou a permissão do Windows não oferece aquela informação. Isso não autoriza elevar permissões ou alterar configurações automaticamente.

## Compartilhamento seguro

1. Abra primeiro o arquivo Markdown.
2. Não envie a pasta inteira.
3. Não publique o JSON no repositório.
4. Compartilhe o JSON somente nesta conversa quando solicitado para análise.
5. Caso identifique qualquer dado pessoal inesperado, interrompa o compartilhamento e registre o problema na Issue #4.

## Limites

Esta fase diagnostica. Não corrige, não atualiza e não limpa. Qualquer manutenção será planejada posteriormente com evidência, risco e aprovação explícita.
