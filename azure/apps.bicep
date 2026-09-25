// Container Apps (web + worker) i el Job de migració/seed per a OpenProject.
// Es desplega en un segon pas, un cop la imatge customitzada ja existeix a l'ACR
// (vegeu azure/deploy.sh), ja que Container Apps no arrenca si la imatge referenciada
// encara no existeix al registre.
targetScope = 'resourceGroup'

param appName string = 'openproject'
param location string = resourceGroup().location

param containerAppsEnvironmentId string
param containerAppsEnvironmentDefaultDomain string
param envStorageName string

param acrLoginServer string
param acrAdminUsername string
@secure()
param acrAdminPassword string

@secure()
param databaseUrl string
@secure()
param secretKeyBase string

param communicationServiceEndpoint string
@secure()
param communicationServiceKey string
param emailSenderAddress string

@description('Imatge completa amb tag, p.ex. myacr.azurecr.io/openproject:1.0')
param image string

var webAppName = '${appName}-web'
var workerAppName = '${appName}-worker'
var seederJobName = '${appName}-seeder'
var hostName = '${webAppName}.${containerAppsEnvironmentDefaultDomain}'

var secretsList = [
  { name: 'acr-password', value: acrAdminPassword }
  { name: 'database-url', value: databaseUrl }
  { name: 'secret-key-base', value: secretKeyBase }
  { name: 'acs-email-key', value: communicationServiceKey }
]

var registries = [
  {
    server: acrLoginServer
    username: acrAdminUsername
    passwordSecretRef: 'acr-password'
  }
]

var sharedEnv = [
  { name: 'RAILS_ENV', value: 'production' }
  { name: 'OPENPROJECT_HOST__NAME', value: hostName }
  { name: 'OPENPROJECT_ATTACHMENTS_SKIP_CHMOD', value: 'true' }
  { name: 'SECRET_KEY_BASE', secretRef: 'secret-key-base' }
  { name: 'DATABASE_URL', secretRef: 'database-url' }
  { name: 'OPENPROJECT_HTTPS', value: 'true' }
  { name: 'OPENPROJECT_HSTS', value: 'true' }
  { name: 'OPENPROJECT_RAILS__CACHE__STORE', value: 'file_store' }
  { name: 'OPENPROJECT_COLLABORATIVE__EDITING__HOCUSPOCUS__URL', value: '' }
  { name: 'IMAP_ENABLED', value: 'false' }
  { name: 'RAILS_MIN_THREADS', value: '4' }
  { name: 'RAILS_MAX_THREADS', value: '16' }
  { name: 'OPENPROJECT_EMAIL__DELIVERY__METHOD', value: 'acs' }
  { name: 'AZURE_ACS_EMAIL_ENDPOINT', value: communicationServiceEndpoint }
  { name: 'AZURE_ACS_EMAIL_KEY', secretRef: 'acs-email-key' }
  { name: 'AZURE_ACS_EMAIL_SENDER_ADDRESS', value: emailSenderAddress }
]

var volumes = [
  {
    name: 'assets'
    storageType: 'AzureFile'
    storageName: envStorageName
  }
]

var volumeMounts = [
  {
    volumeName: 'assets'
    mountPath: '/var/openproject/assets'
  }
]

resource webApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: webAppName
  location: location
  properties: {
    environmentId: containerAppsEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      secrets: secretsList
      registries: registries
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'web'
          image: image
          command: [
            './docker/prod/web'
          ]
          env: sharedEnv
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
          volumeMounts: volumeMounts
          probes: [
            {
              // Rails eager-loads the whole application (dozens of engines/plugins) before
              // Puma binds the port, which takes longer than Container Apps' default TCP
              // startup/liveness probes allow, killing the container mid-boot. These explicit
              // probes override the defaults with enough headroom for a cold boot.
              type: 'Startup'
              httpGet: {
                path: '/health_checks/default'
                port: 8080
              }
              initialDelaySeconds: 10
              periodSeconds: 10
              failureThreshold: 30
            }
            {
              type: 'Liveness'
              httpGet: {
                path: '/health_checks/default'
                port: 8080
              }
              initialDelaySeconds: 30
              periodSeconds: 10
              failureThreshold: 6
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health_checks/default'
                port: 8080
              }
              initialDelaySeconds: 30
              periodSeconds: 10
              failureThreshold: 6
            }
          ]
        }
      ]
      volumes: volumes
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

resource workerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: workerAppName
  location: location
  properties: {
    environmentId: containerAppsEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      secrets: secretsList
      registries: registries
    }
    template: {
      containers: [
        {
          name: 'worker'
          image: image
          command: [
            './docker/prod/worker'
          ]
          env: sharedEnv
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          volumeMounts: volumeMounts
        }
      ]
      volumes: volumes
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

resource seederJob 'Microsoft.App/jobs@2024-03-01' = {
  name: seederJobName
  location: location
  properties: {
    environmentId: containerAppsEnvironmentId
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 900
      replicaRetryLimit: 0
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
      secrets: secretsList
      registries: registries
    }
    template: {
      containers: [
        {
          name: 'seeder'
          image: image
          command: [
            './docker/prod/seeder'
          ]
          env: sharedEnv
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          volumeMounts: volumeMounts
        }
      ]
      volumes: volumes
    }
  }
}

output webUrl string = 'https://${hostName}'
output seederJobName string = seederJobName
