# Inventário preliminar de aplicativos protegidos

Este inventário foi montado a partir das ferramentas declaradas nos projetos KARV. A presença, edição e versão instalada ainda serão verificadas localmente na Fase 1.

## Classificações

- `PROTEGIDO`: não remover, redefinir, reparar ou atualizar sem aprovação específica.
- `CONTROLADO`: pode receber manutenção após análise de impacto e procedimento de reversão.
- `REMOVÍVEL`: candidato a remoção após confirmação de que não possui dependências.
- `DESCONHECIDO`: requer identificação antes de qualquer ação.

## Lista inicial

| Aplicativo ou componente | Versão de referência | Classificação inicial | Motivo | Verificação local |
|---|---:|---|---|---|
| Rhino | 8 | PROTEGIDO | Modelagem e conversão de geometrias KARV | Pendente |
| Blender | A confirmar | PROTEGIDO | Validação 3D, UV, bake e publicação | Pendente |
| Adobe Substance 3D Sampler | A confirmar | PROTEGIDO | Pipeline principal de materiais PBR | Pendente |
| Git | A confirmar | PROTEGIDO | Controle de versão dos projetos | Pendente |
| Node.js | 22 como referência operacional | PROTEGIDO | Builds, testes e ferramentas KARV | Pendente |
| npm | Vinculada ao Node.js | PROTEGIDO | Dependências dos projetos web | Pendente |
| PowerShell | A confirmar | PROTEGIDO | Administração e automação local | Pendente |
| Navegador principal | A confirmar | CONTROLADO | GitHub, Cloudflare, Netlify e operação web | Pendente |
| Driver da GPU | A confirmar | CONTROLADO | Estabilidade de modelagem e renderização | Pendente |
| Windows Defender e Firewall | Sistema | PROTEGIDO | Segurança do equipamento | Pendente |

## Dependências que devem ser mapeadas

Para cada aplicativo protegido, registrar futuramente:

- edição e versão completa;
- origem da instalação;
- licença e método de ativação sem registrar a chave;
- plugins, extensões, presets e bibliotecas;
- pastas de configuração e cache;
- formato de backup;
- compatibilidade com GPU, Windows e demais ferramentas;
- procedimento de atualização e reversão.

## Regra provisória

Até a conclusão da Fase 2, qualquer aplicativo não identificado deve ser tratado como `DESCONHECIDO`, e nenhum aplicativo desta lista pode ser alterado automaticamente.
