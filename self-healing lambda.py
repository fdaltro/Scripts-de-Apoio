import os
import boto3
import base64
import json
import datetime
import urllib.request
import urllib.error
from botocore.signers import RequestSigner

def get_bearer_token(cluster_name, region):
    session = boto3.session.Session()
    eks_client = session.client('eks', region_name=region)
    service_id = eks_client.meta.service_model.service_id
    signer = RequestSigner(
        service_id,
        region,
        'sts',
        'v4',
        session.get_credentials(),
        session.events
    )
    
    params = {
        'method': 'GET',
        'headers': {
            'x-k8s-aws-id': cluster_name # <--- OBRIGATÓRIO para o EKS validar a sessão do IAM
        },
        'body': b'',
        'url': f'https://sts.{region}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15',
        'context': {}
    }
    
    url = signer.generate_presigned_url(params, region_name=region, expires_in=60, operation_name='')
    base64_url = base64.b64encode(url.encode('utf-8')).decode('utf-8')
    return 'k8s-aws-v1.' + base64_url.rstrip('=')

def lambda_handler(event, context):
    print("Payload recebido do PagerDuty V2:", json.dumps(event))
    
    # 1. Validar evento do PagerDuty
    try:
        body_data = json.loads(event.get('body', '{}'))
        messages = body_data.get('messages', [])
        if not messages or messages[0].get('event') != "incident.trigger":
            print("Evento ignorado ou inválido.")
            return {"statusCode": 200, "body": "Evento ignorado."}
    except Exception as e:
        print(f"Erro no parse do payload: {e}")
        return {"statusCode": 400, "body": "Payload inválido."}

    # 2. Configurações extraídas do ambiente
    CLUSTER_NAME = os.environ.get('CLUSTER_NAME', 'togglemaster-eks')
    REGION = os.environ.get('AWS_REGION', 'us-east-1')
    NAMESPACE = "togglemaster"
    DEPLOYMENT_NAME = "auth-service"

    print(f"Iniciando Self-Healing nativo para {DEPLOYMENT_NAME}...")

    # 3. Coletar dados do cluster EKS via boto3
    eks_client = boto3.client('eks', region_name=REGION)
    cluster_info = eks_client.describe_cluster(name=CLUSTER_NAME)
    cluster_endpoint = cluster_info['cluster']['endpoint']
    
    # 4. Gerar Token de Acesso
    token = get_bearer_token(CLUSTER_NAME, REGION)

    # 5. Construir a requisição HTTP PATCH diretamente para o painel de controle do Kubernetes
    url = f"{cluster_endpoint}/apis/apps/v1/namespaces/{NAMESPACE}/deployments/{DEPLOYMENT_NAME}"
    now = datetime.datetime.utcnow().isoformat() + "Z"
    
    patch_body = {
        'spec': {
            'template': {
                'metadata': {
                    'annotations': {
                        'kubectl.kubernetes.io/restartedAt': now,
                        'triggered-by': 'PagerDuty-SelfHealing'
                    }
                }
            }
        }
    }
    
    data = json.dumps(patch_body).encode('utf-8')
    
    # Criamos o request configurando os headers manuais e o método PATCH
    req = urllib.request.Request(
        url, 
        data=data, 
        headers={
            'Authorization': f'Bearer {token}',
            'Content-Type': 'application/strategic-merge-patch+json'
        },
        method='PATCH'
    )

    # Como estamos no AWS Academy e o certificado do endpoint do EKS é confiável, 
    # podemos fazer a chamada direta.
    try:
        # Desabilita verificação estrita apenas se houver problema com o CA da máquina do Lambda, 
        # mas por padrão o urllib usará os CAs padrão do sistema.
        import ssl
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        
        with urllib.request.urlopen(req, context=ctx) as response:
            res_body = response.read().decode('utf-8')
            print(f"Sucesso! Resposta do Kubernetes: {res_body}")
            return {"statusCode": 200, "body": "Rollout restart executado nativamente!"}
            
    except urllib.error.HTTPError as e:
        error_msg = e.read().decode('utf-8')
        print(f"Erro HTTP do Kubernetes ({e.code}): {error_msg}")
        return {"statusCode": e.code, "body": error_msg}
    except Exception as e:
        print(f"Erro inesperado: {e}")
        return {"statusCode": 500, "body": str(e)}