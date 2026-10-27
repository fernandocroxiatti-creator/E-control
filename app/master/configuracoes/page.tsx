import { PreparedCapability } from "@/app/master/master-data-ui";

export default function MasterSettingsPage() {
  return <PreparedCapability title="Configurações SaaS" description="Parâmetros globais do serviço." reason="Chaves, URLs de autenticação, políticas e limites não são expostos nem editáveis pelo painel. Alterações de ambiente exigem operação revisada fora da aplicação." />;
}
