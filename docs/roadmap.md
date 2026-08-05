# Roadmap técnico — KARV Laptop

## Objetivo

Construir uma rotina controlada para diagnóstico, estabilidade, manutenção e automação do laptop KARV sem comprometer aplicativos, licenças, projetos ou credenciais.

## Fase 0 — Fundação e governança

**Estado:** em execução

- [x] Inicializar o repositório.
- [x] Definir escopo e limites operacionais.
- [x] Criar política de segurança e dados locais.
- [x] Definir padrão de branches, commits e Pull Requests.
- [x] Criar inventário preliminar de aplicativos protegidos.
- [x] Criar estrutura de diretórios.
- [ ] Revisar e aprovar a PR da Fase 0.

**Saída:** repositório preparado para receber scripts e diagnósticos sem expor dados locais.

## Fase 1 — Diagnóstico somente leitura

- [ ] Identificar versão e build do Windows.
- [ ] Levantar CPU, RAM, GPU e armazenamento.
- [ ] Verificar saúde lógica e SMART do SSD quando disponível.
- [ ] Mapear processos, serviços e itens de inicialização.
- [ ] Levantar aplicativos instalados e versões.
- [ ] Verificar drivers relevantes.
- [ ] Coletar eventos críticos e erros recorrentes do Windows.
- [ ] Mapear caches técnicos e consumo de armazenamento.
- [ ] Gerar relatório local sanitizável.

**Regra:** nenhuma alteração no sistema durante esta fase.

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
