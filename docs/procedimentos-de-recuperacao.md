# Procedimentos de recuperação

## Objetivo

Definir a preparação mínima antes de qualquer manutenção capaz de afetar o Windows, drivers, aplicativos protegidos ou projetos locais.

## Níveis de recuperação

### Nível 1 — Reversão de configuração

Aplicável a alterações pequenas e documentadas. Registrar o valor anterior, o valor novo e o comando ou caminho para desfazer.

### Nível 2 — Ponto de restauração

Aplicável antes de alterações em drivers, serviços, registro, componentes do Windows ou instalações com impacto sistêmico. Confirmar que a Proteção do Sistema está ativa e que o ponto foi criado com sucesso.

### Nível 3 — Backup de aplicativo

Aplicável antes de atualizar ou reparar aplicativos protegidos. Preservar configurações, presets, plugins e dados necessários para reinstalação, sem versionar licenças ou credenciais.

### Nível 4 — Backup de dados

Aplicável antes de limpeza ampla, reorganização de armazenamento ou manutenção de disco. Confirmar cópia dos projetos críticos em destino independente do disco afetado.

## Checklist antes da mudança

- [ ] Motivo e escopo registrados.
- [ ] Aplicativos afetados identificados.
- [ ] Projetos abertos salvos e fechados.
- [ ] Backup compatível com o risco concluído.
- [ ] Procedimento de reversão definido.
- [ ] Fonte do instalador ou driver confirmada.
- [ ] Aprovação explícita registrada.

## Falha durante manutenção

1. Interromper ações adicionais.
2. Registrar o erro sem expor dados sensíveis.
3. Não executar limpadores, reparadores ou comandos aleatórios.
4. Verificar se o sistema permanece inicializável e se os dados estão acessíveis.
5. Aplicar o menor procedimento de reversão adequado.
6. Validar os aplicativos protegidos após a recuperação.

## Validação posterior

- Windows inicia sem novo erro crítico.
- Rede e armazenamento funcionam.
- Aplicativos protegidos abrem e mantêm suas configurações.
- Licenças permanecem válidas.
- Um fluxo representativo de trabalho é executado.
- A alteração e o resultado são registrados.
