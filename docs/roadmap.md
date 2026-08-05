# Roadmap técnico — KARV Laptop

## Objetivo

Construir uma rotina controlada para diagnóstico, estabilidade, manutenção e automação do laptop KARV sem comprometer aplicativos, licenças, projetos ou credenciais.

## Fase 0 — Fundação e governança

**Estado:** concluída pela PR #3

- [x] Inicializar o repositório.
- [x] Definir escopo e limites operacionais.
- [x] Criar política de segurança e dados locais.
- [x] Definir padrão de branches, commits e Pull Requests.
- [x] Criar inventário preliminar de aplicativos protegidos.
- [x] Criar estrutura de diretórios.
- [x] Revisar, aprovar e incorporar a PR da Fase 0.

**Saída:** repositório preparado para receber scripts e diagnósticos sem expor dados locais.

## Fase 1 — Diagnóstico somente leitura

**Estado:** implementação em andamento na Issue #4

### Implementação

- [x] Criar script PowerShell somente leitura.
- [x] Sanitizar nomes de usuário, computador, caminhos, e-mail, MAC e IP.
- [x] Excluir serial, UUID, comandos de inicialização e mensagens completas de eventos.
- [x] Bloquear saída dentro de repositórios Git.
- [x] Criar validação estática de sintaxe e comandos proibidos.
- [x] Criar check automático em runner Windows.
- [x] Documentar execução e compartilhamento seguro.
- [ ] Revisar e aprovar a PR da implementação.

### Coleta local

- [ ] Identificar versão e build do Windows.
- [ ] Levantar CPU, RAM, GPU e armazenamento.
- [ ] Verificar saúde lógica e indicadores do SSD quando disponíveis.
- [ ] Mapear processos e itens de inicialização.
- [ ] Levantar aplicativos instalados e versões.
- [ ] Verificar drivers relevantes.
- [ ] Coletar resumo agregado de eventos críticos e erros recorrentes.
- [ ] Mapear caches técnicos e consumo de armazenamento.
- [ ] Gerar relatório local sanitizado.
- [ ] Analisar resultados e registrar linha de base.

**Regra:** nenhuma alteração no sistema durante esta fase. A única escrita permitida é a criação dos relatórios locais fora do repositório.

## Fase 2 — Catálogo de aplicativos críticos

- [ ] Confirmar presença e versão de cada aplicativo.
- [ ] Classificar como `PROTEGIDO`, `CONTROLADO`, `REMOVÍVEL` ou `DESCONHECIDO`.
- [ ] Mapear plugins, presets, licenças e dependências.
- [ ] Definir política de atualização individual.
- [ ] Registrar procedimentos de backup e recuperação.

## Fase 3 — Estabilidade do Windows

- [ ] Verificar integridade do sistema.
- [ ] Revisar inicialização e serviços.
- [ ] Revisar plano de energia e memória virtual.
- [ ] Validar Defender, firewall e Windows Update.
- [ ] Revisar tarefas agendadas relevantes.
- [ ] Configurar ponto de recuperação antes de mudanças críticas.

## Fase 4 — Otimização técnica

- [ ] Rhino 8.
- [ ] Blender.
- [ ] Adobe Substance 3D Sampler.
- [ ] GPU e drivers.
- [ ] Caches, recuperação automática, render e bake.
- [ ] Armazenamento temporário de projetos 3D.

## Fase 5 — Ambiente de desenvolvimento KARV

- [ ] Git e credenciais locais.
- [ ] Node.js, npm e versões aprovadas.
- [ ] PowerShell.
- [ ] Repositórios locais e branches pendentes.
- [ ] Dependências, builds e caches acumulados.
- [ ] Portas e processos de desenvolvimento.

## Fase 6 — Automação local

- [ ] Script de diagnóstico.
- [ ] Script de monitoramento.
- [ ] Script de verificação de aplicativos.
- [ ] Script de limpeza segura.
- [ ] Script de verificação de repositórios.
- [ ] Sanitização de logs e relatórios.

## Fase 7 — Rotina permanente

- [ ] Verificação semanal.
- [ ] Manutenção mensal.
- [ ] Registro de versões aprovadas.
- [ ] Procedimento de recuperação.
- [ ] Revisão trimestral dos aplicativos protegidos.

## Regras transversais

- Diagnóstico antes de manutenção.
- Nenhuma alteração destrutiva sem aprovação.
- Aplicativos protegidos não são atualizados automaticamente.
- Relatórios reais permanecem locais.
- Toda automação deve registrar o que verificou e o que alterou.
