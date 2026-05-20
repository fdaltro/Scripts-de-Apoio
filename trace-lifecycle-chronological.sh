#!/bin/bash

# Configurações dos Endpoints (Port-Forwards ativos)
AUTH_KEY="admin-secreto-123"
FLAG_SVC="http://localhost:8002"
TARGETING_SVC="http://localhost:8003"
EVAL_SVC="http://localhost:8004"
FLAG_NAME="redis-proof-flag"
QUEUE_URL="https://sqs.us-east-1.amazonaws.com/504491092699/togglemaster-queue"

echo "================================================================="
echo "⏱️  INICIANDO VALIDAÇÃO CRONOLÓGICA DO REDIS + TRACES"
echo "================================================================="

# -----------------------------------------------------------------
# FASE 1: CRIAÇÃO DO CENÁRIO
# -----------------------------------------------------------------
echo -e "\n1️⃣  [PROVIMENTO] Criando a flag no banco de dados..."
curl -s -X POST "$FLAG_SVC/flags" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $AUTH_KEY" \
  -d "{\"name\": \"$FLAG_NAME\", \"description\": \"Flag para comprovar o Redis\", \"is_enabled\": true}"
echo ""

echo -e "\n2️⃣  [PROVIMENTO] Atrelando regra de 50% de amostragem..."
curl -s -X POST "$TARGETING_SVC/rules" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $AUTH_KEY" \
  -d "{\"flag_name\": \"$FLAG_NAME\", \"is_enabled\": true, \"rules\": {\"rule_type\": \"PERCENTAGE\", \"value\": 50}}"
echo ""
echo "-----------------------------------------------------------------"

# -----------------------------------------------------------------
# FASE 2: A PROVA REAL DO REDIS (Chamadas Isoladas)
# -----------------------------------------------------------------
echo -e "\n3️⃣  [REDIS PROOF - PASSO A] Primeira chamada (Cache Frio)"
echo "👉 Olhe seus logs do Go agora! Deve aparecer: 'Cache MISS para flag $FLAG_NAME'"
curl -s "$EVAL_SVC/evaluate?user_id=user-999&flag_name=$FLAG_NAME"
echo -e "\n[Aguardando 2 segundos para o Redis consolidar...]"
sleep 2

echo -e "\n4️⃣  [REDIS PROOF - PASSO B] Segunda chamada idêntica (Cache Quente)"
echo "👉 Olhe seus logs do Go agora! Deve aparecer: 'Cache HIT para flag $FLAG_NAME'"
curl -s "$EVAL_SVC/evaluate?user_id=user-999&flag_name=$FLAG_NAME"
echo ""
echo "-----------------------------------------------------------------"

# -----------------------------------------------------------------
# FASE 3: VOLUMETRIA E TRACES (Para colorir o Datadog)
# -----------------------------------------------------------------
echo -e "\n🔄 Ativando loop de envio direto ao SQS em segundo plano (Sleep 2)..."
send_sqs_background() {
  while true; do
    aws sqs send-message --queue-url "$QUEUE_URL" \
      --message-body "{
        \"user_id\": \"aws-shell-user\",
        \"flag_name\": \"$FLAG_NAME\",
        \"result\": true,
        \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
      }" > /dev/null && echo "📥 [AWS-CLI] Mensagem enviada diretamente ao SQS às $(date +%H:%M:%S)"
    sleep 2
  done
}
send_sqs_background &
SQS_PID=$!

echo -e "\n5️⃣  [ESTRESSE] Disparando 1000 requisições com a flag aquecida no Redis..."
echo "A partir daqui, o Datadog vai registrar latências lindamente baixas porque o Redis blindou o Postgres."
hey -n 1000 -c 20 "$EVAL_SVC/evaluate?user_id=user-999&flag_name=$FLAG_NAME"
echo -e "\n-----------------------------------------------------------------"

# -----------------------------------------------------------------
# FASE 4: LIMPEZA DO CENÁRIO
# -----------------------------------------------------------------
echo -e "\n🛑 Desativando loop de envio do SQS (PID: $SQS_PID)..."
kill $SQS_PID 2>/dev/null

echo -e "\n6️⃣  [CLEANUP] Removendo os dados de teste..."
curl -s -X DELETE -H "Authorization: Bearer $AUTH_KEY" "$TARGETING_SVC/rules/$FLAG_NAME"
curl -s -X DELETE -H "Authorization: Bearer $AUTH_KEY" "$FLAG_SVC/flags/$FLAG_NAME"
echo -e "\nAmbiente limpo com sucesso."

echo "================================================================="
echo "🎯 CONCLUÍDO! Verifique a cronologia perfeita nos seus logs e no Datadog!"
echo "================================================================="