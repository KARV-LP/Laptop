# Fluxo de trabalho

## Branches

- `main`: somente conteúdo aprovado.
- `phase-N-descricao`: implementação de uma fase do roadmap.
- `fix/descricao`: correção isolada.
- `docs/descricao`: alteração exclusivamente documental.

## Commits

Usar mensagens objetivas no padrão:

- `docs: ...`
- `feat: ...`
- `fix: ...`
- `chore: ...`
- `test: ...`

Cada commit deve representar uma alteração verificável e não deve incluir relatórios locais, credenciais ou arquivos comerciais.

## Pull Requests

1. Criar branch a partir da `main` atualizada.
2. Abrir PR como draft durante a execução.
3. Relacionar a issue correspondente.
4. Descrever escopo, riscos, validações e intervenção necessária do usuário.
5. Não fazer merge sem aprovação explícita.
6. Preferir squash merge quando a PR contiver muitos commits operacionais pequenos.

## Critérios mínimos de aprovação

- nenhuma credencial ou identificação local exposta;
- documentação coerente com o comportamento real;
- scripts com tratamento de erro e saída compreensível;
- modo somente leitura ou `dry-run` validado antes de manutenção;
- impacto e procedimento de reversão registrados;
- aplicativos protegidos preservados.
