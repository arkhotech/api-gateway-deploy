#!/bin/bash
set -e

ACCOUNT_ID=$(aws sts get-caller-identity | jq -r '.Account')

aws eks update-kubeconfig --region ${AWS_DEFAULT_REGION} --name ${INPUT_EKS_CLUSTER_NAME}

if [ ! -z "$INPUT_ENVIRONMENT" ];
then 
    ENVIRONMENT=$INPUT_ENVIRONMENT
fi

PROJECT=$INPUT_PROJECT

echo "Revisando balancers asciado al servicio $SERVICE_NAME"
NLB_LIST=$(aws elbv2 describe-load-balancers | jq -r ' [  .LoadBalancers[] | select( .Type=="network" ) |   { arn: .LoadBalancerArn, hostname: .DNSName } ] ')

EKS_SERVICE_HOSTNAME=$(/kubectl get services -l cpat.service=$SERVICE_NAME -n cpat -o json | jq -r ' .items[].status.loadBalancer.ingress[].hostname')

echo "Buscando NLB: $EKS_SERVICE_HOSTNAME"

if [ -z "$EKS_SERVICE_HOSTNAME" ];
then
    echo "No se ha encotrado el servicio etiquetado como $EKS_SERVICE_HOSTNAME"
    echo "Revisar que la etiqueta (label) 'cpat.service' tenga el nombre dek servicio $EKS_SERVICE_HOSTNAME"
    exit 1
fi
#Al menos un NLB debe salir desde acá, sino lo hay, se supone que no se ha levantado
ARN=$(echo $NLB_LIST | jq --arg h $EKS_SERVICE_HOSTNAME -r '.[] | select( .hostname == $h ) | .arn' )

if [ -z "$ARN" ];
then
    echo "El servicio $SERVICE_NAME, no tiene asociado un NLB"
    exit 1
fi

#Listar los links que estan desplegados
VPC_LINK_ID=$(aws apigateway get-vpc-links | jq -r --arg t $ARN ' .items[] | select( .targetArns[] == $t ) | .id ')
echo "Resultado de la busqueda: $VPC_LINK_ID"
echo "Verificar si existe VPC Link"



if [ -z "$VPC_LINK_ID" ];
then
    echo "No existe el VPC Link, procediendo a crearlo"
    echo "$PROJECT-$SERVICE_NAME-$ENVIRONMENT-link"

    VPC_LINK_RES=$(aws apigateway create-vpc-link \
        --name "$PROJECT-$SERVICE_NAME-$ENVIRONMENT-link" \
        --description "Link para API servicio $SERVICE_NAME en ambiente $ENVIRONMENT" \
        --target-arns "$ARN" \
        --tags "Environment=$ENVIRONMENT,Project=$PROJECT,Purpose=API")

    echo $VPC_LINK_RES

    VPC_LINK_ID=$(echo $VPC_LINK_RES | jq -r '.id' )

    
else
    echo "Ya existe NLB para el servicio $SERVICE_NAME"
    echo "VPCLink ID: $VPC_LINK_ID"

fi


#Actualizando API

API_NAME="$PROJECT-$ENVIRONMENT-$SERVICE_NAME-api"

#Check si existe api gateway 
API_DATA=$(aws apigateway get-rest-apis | jq -r --arg n $API_NAME ' .items[] | select( .name == $n)')

ID=$(echo "$API_DATA" | jq -r '.id')

if [ -z ${ID} ];
then
    echo "Creando API Gateway $API_NAME"
    
    API_DATA=$(aws apigateway create-rest-api --name=$API_NAME \
                        --endpoint-configuration "types=REGIONAL" \
                        --description "API Gateway servicio $SERVICE_NAME")

    ID=$(echo "$API_DATA" | jq -r '.id')
    echo "APi gateway con Id: $ID, se ha creado" 

    echo "Creando Stage"

fi

#Reemplazo de valores para lambda authorizer
cp ./$INPUT_SWAGGER_PATH ./swagger_temp.yaml

sed -i 's/API_NAME/'$API_NAME'/g' ./swagger_temp.yaml

sed -i 's/ACCOUNT_ID/'$ACCOUNT_ID'/g'  ./swagger_temp.yaml

sed -i 's/REGION/'$AWS_DEFAULT_REGION'/g'  ./swagger_temp.yaml

# Reemplazo de variable CORS DOMAIN
sed -i 's/CORS_DOMAIN/'$INPUT_CORS_DOMAIN'/g' ./swagger_temp.yaml

cat  ./swagger_temp.yaml

if [[ "$OSTYPE" == "linux-gnu"* ]];
then
    echo "$OSTYPE"
    base64 ./swagger_temp.yaml > ./swager_body.b64
else
    base64 -i ./swagger_temp.yaml -o ./swager_body.b64
fi 
    
echo "Actualizando API $ID"

aws apigateway put-rest-api --rest-api-id $ID \
        --body file://./swager_body.b64 


EXISTS_DEPLOYMENT=$(aws apigateway get-deployments --rest-api-id $ID | jq -r '.items | length ')

echo "Deployment sobre API $ID"
echo "VPCLink: $VPC_LINK_ID"
echo "NLB: $EKS_SERVICE_HOSTNAME"
echo "AUTH_FUNC:  $INPUT_AUTHORIZER_FUNCTION"
echo "AUTH_ROL: $INPUT_AUTHORIZER_ROLE_NAME"


if [ "${EXISTS_DEPLOYMENT}"=="0" ];
then
    echo "Creando deployment sobre"
    aws apigateway create-deployment \
        --rest-api-id $ID \
        --stage-name $INPUT_STAGE_NAME \
        --variables "url=$EKS_SERVICE_HOSTNAME,vpcLinkId=$VPC_LINK_ID,cpat_authorizer=$INPUT_AUTHORIZER_FUNCTION,cpat_authorizer_role=$INPUT_AUTHORIZER_ROLE_NAME" 
else
    echo "Actualizando"
    $DEPLOYMENT_ID=$(aws apigateway get-deployments --rest-api-id $ID | jq -r '.items[0] |  .id')
    aws apigateway update-deployment \
        --rest-api-id $ID \
        --deployment-id $DEPLOYMENT_ID
fi

