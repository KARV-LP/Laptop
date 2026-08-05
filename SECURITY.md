# Política de segurança e dados locais

## Classificação do repositório

Este repositório é público. Portanto, somente documentação genérica, scripts sanitizados, configurações de exemplo e evidências sem identificação podem ser versionados.

## Dados proibidos

Nunca publicar:

- senhas, tokens, cookies, chaves SSH ou arquivos `.env`;
- números de série, service tags, UUIDs, MAC addresses ou identificadores de hardware;
- nomes de usuário do Windows, nomes reais de pastas pessoais ou caminhos completos do perfil;
- chaves de licença, comprovantes, contratos ou dados de conta;
- relatórios brutos do Windows, logs completos ou dumps de memória;
- listas de redes Wi-Fi, IPs públicos ou credenciais salvas;
- arquivos de projetos KARV, modelos 3D, texturas ou materiais comerciais.

## Tratamento de relatórios

1. O diagnóstico gera dados em pasta local fora do controle de versão.
2. Antes de qualquer compartilhamento, o relatório deve ser sanitizado.
3. A versão sanitizada deve remover identificadores, caminhos pessoais e dados comerciais.
4. O diretório `reports/` mantém apenas arquivos de exemplo ou evidências explicitamente aprovadas.

## Execução segura

- Scripts de diagnóstico devem ser somente leitura por padrão.
- Scripts de manutenção devem oferecer modo de simulação (`dry-run`) quando tecnicamente possível.
- Ações destrutivas exigem confirmação explícita e ponto de recuperação adequado.
- Nenhum script deve desativar Defender, firewall, UAC ou atualizações de segurança de forma permanente.
- Nenhum script deve coletar ou transmitir dados para serviços externos sem documentação e aprovação.

## Incidente

Caso um dado sensível seja publicado:

1. interromper novas alterações;
2. revogar imediatamente qualquer credencial exposta;
3. remover o conteúdo do histórico Git quando necessário;
4. registrar o incidente sem repetir o segredo;
5. revisar a regra ou script que permitiu a exposição.
