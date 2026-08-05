# KARV Laptop

Sistema técnico para diagnóstico, manutenção, estabilidade e automação segura do laptop utilizado nos projetos KARV.

## Escopo

Este repositório controla procedimentos, scripts e evidências sanitizadas para:

- diagnosticar Windows, hardware, armazenamento e processos;
- preservar aplicativos críticos da operação KARV;
- manter o ambiente 3D e de desenvolvimento;
- executar limpeza e otimização somente após validação;
- registrar versões, decisões e procedimentos de recuperação.

## Limites operacionais

- Nenhuma remoção, atualização crítica ou alteração destrutiva sem aprovação explícita.
- O diagnóstico deve ocorrer antes da manutenção.
- Scripts novos começam em modo somente leitura.
- Aplicativos classificados como `PROTEGIDO` não podem ser removidos ou atualizados automaticamente.
- Relatórios reais permanecem locais e não são versionados.
- Senhas, tokens, licenças, números de série, nomes de usuário, caminhos pessoais e identificadores do equipamento não podem entrar no GitHub.
- A branch `main` contém apenas versões aprovadas.

## Estrutura

```text
Laptop/
├── README.md
├── SECURITY.md
├── CONTRIBUTING.md
├── docs/
│   ├── roadmap.md
│   ├── aplicativos-protegidos.md
│   ├── politica-de-atualizacao.md
│   └── procedimentos-de-recuperacao.md
├── scripts/
│   ├── diagnostic/
│   ├── maintenance/
│   └── monitoring/
├── config/
│   └── examples/
└── reports/
```

## Estado atual

A **Fase 0 — Fundação e governança** está em desenvolvimento. O primeiro diagnóstico local será executado somente na Fase 1, após aprovação da estrutura inicial.

## Roadmap

O planejamento completo está em [`docs/roadmap.md`](docs/roadmap.md).
