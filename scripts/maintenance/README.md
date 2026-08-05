# Scripts de manutenção

Esta pasta receberá rotinas de manutenção controlada a partir da Fase 3.

Todo script deve:

- explicar o impacto antes da execução;
- oferecer `dry-run` quando possível;
- exigir confirmação para ações destrutivas;
- registrar o que foi alterado;
- preservar aplicativos protegidos;
- documentar reversão e pré-requisitos;
- falhar com segurança quando o estado do sistema for desconhecido.

Nenhuma rotina de limpeza genérica será adicionada sem critérios específicos e validação.
