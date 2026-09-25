// Infraestructura base per a OpenProject a Azure (Container Apps).
// Pensat per a una subscripció sense permisos per crear assignacions de rol (RBAC):
// no s'utilitza Key Vault ni identitats gestionades; els secrets viatgen com a
// "secrets" natius de Container Apps i les credencials de recursos (ACR, Storage,
// Communication Services) s'obtenen via access key / usuari-contrasenya.
targetScope = 'resourceGroup'

@description('Prefix curt per als noms de recursos (sense majúscules ni caràcters especials)')
param appName string = 'openproject'

param location string = resourceGroup().location

@description('Regió de dades per als recursos de Communication Services')
param communicationDataLocation string = 'Europe'

@secure()
@description('Contrasenya de l\'usuari administrador de PostgreSQL')
param postgresAdminPassword string

param postgresAdminLogin string = 'openproject'
param postgresVersion string = '17'
param postgresSkuName string = 'Standard_B1ms'
param postgresStorageSizeGB int = 32

var uniqueSuffix = uniqueString(resourceGroup().id)
var storageAccountName = toLower(substring('st${appName}${uniqueSuffix}', 0, 24))
var acrName = toLower('acr${appName}${uniqueSuffix}')
var postgresServerName = toLower('psql-${appName}-${uniqueSuffix}')
var logAnalyticsName = 'log-${appName}'
var containerAppsEnvName = 'cae-${appName}'
var fileShareName = 'attachments'

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerAppsEnvName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileService
  name: fileShareName
  properties: {
    shareQuota: 20
  }
}

resource envStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: containerAppsEnvironment
  name: 'attachments'
  properties: {
    azureFile: {
      accountName: storageAccount.name
      accountKey: storageAccount.listKeys().keys[0].value
      shareName: fileShare.name
      accessMode: 'ReadWrite'
    }
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    // Admin user (usuari/contrasenya) en lloc de AcrPull via managed identity,
    // ja que aquesta subscripció no permet assignacions de rol RBAC.
    adminUserEnabled: true
  }
}

resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: postgresServerName
  location: location
  sku: {
    name: postgresSkuName
    tier: 'Burstable'
  }
  properties: {
    version: postgresVersion
    administratorLogin: postgresAdminLogin
    administratorLoginPassword: postgresAdminPassword
    storage: {
      storageSizeGB: postgresStorageSizeGB
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
  }
}

resource postgresDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: postgresServer
  name: 'openproject'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// Permet l'accés des de qualsevol servei d'Azure (Container Apps no ofereix una
// IP de sortida estàtica al pla Consumption sense integració de VNet).
resource postgresFirewallAllowAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: postgresServer
  name: 'AllowAllAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// Les migracions d'OpenProject creen aquestes extensions (db/migrate/extensions/*.rb).
// Azure Database for PostgreSQL bloqueja CREATE EXTENSION si no estan a la llista blanca.
resource postgresExtensions 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: postgresServer
  name: 'azure.extensions'
  properties: {
    value: 'btree_gist,pg_trgm,unaccent'
    source: 'user-override'
  }
}

resource emailService 'Microsoft.Communication/emailServices@2023-04-01' = {
  name: 'ecs-${appName}'
  location: 'global'
  properties: {
    dataLocation: communicationDataLocation
  }
}

resource emailDomain 'Microsoft.Communication/emailServices/domains@2023-04-01' = {
  parent: emailService
  name: 'AzureManagedDomain'
  location: 'global'
  properties: {
    domainManagement: 'AzureManaged'
  }
}

resource communicationService 'Microsoft.Communication/communicationServices@2023-04-01' = {
  name: 'cs-${appName}'
  location: 'global'
  properties: {
    dataLocation: communicationDataLocation
    linkedDomains: [
      emailDomain.id
    ]
  }
}

output containerAppsEnvironmentId string = containerAppsEnvironment.id
output containerAppsEnvironmentDefaultDomain string = containerAppsEnvironment.properties.defaultDomain
output envStorageName string = envStorage.name
output acrLoginServer string = acr.properties.loginServer
output acrName string = acr.name
#disable-next-line outputs-should-not-contain-secrets
output acrAdminUsername string = acr.listCredentials().username
#disable-next-line outputs-should-not-contain-secrets
output acrAdminPassword string = acr.listCredentials().passwords[0].value
output postgresFqdn string = postgresServer.properties.fullyQualifiedDomainName
#disable-next-line outputs-should-not-contain-secrets
output databaseUrl string = 'postgres://${postgresAdminLogin}:${uriComponent(postgresAdminPassword)}@${postgresServer.properties.fullyQualifiedDomainName}:5432/openproject?sslmode=require&pool=20&encoding=unicode'
output communicationServiceEndpoint string = 'https://${communicationService.properties.hostName}'
#disable-next-line outputs-should-not-contain-secrets
output communicationServiceKey string = communicationService.listKeys().primaryKey
output emailSenderAddress string = 'DoNotReply@${emailDomain.properties.mailFromSenderDomain}'
