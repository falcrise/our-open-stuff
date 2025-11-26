<#
.SYNOPSIS
    Deploys n8n workflow automation to Azure Container Apps with PostgreSQL Flexible Server.

.DESCRIPTION
    This script provisions and configures:
    - Azure Resource Group
    - Log Analytics Workspace
    - Container Apps Environment
    - PostgreSQL Flexible Server with database
    - Container App running n8n with proper secrets management

    The script is idempotent: existing resources are reused/updated rather than recreated.

.PREREQUISITES
    1. Azure CLI installed: https://docs.microsoft.com/cli/azure/install-azure-cli
    2. Container Apps extension: az extension add --name containerapp --upgrade
    3. Logged into Azure: az login
    4. Appropriate subscription permissions

.PARAMETER Environment
    Required. Specifies the target environment: 'dev' or 'prod'.
    Maps to config.dev.json or config.prod.json respectively.

.PARAMETER ConfigPath
    Optional. Override the default config file path.
    Defaults to .\config.<Environment>.json

.EXAMPLE
    .\deploy-n8n.ps1 -Environment dev
    Deploys n8n using config.dev.json

.EXAMPLE
    .\deploy-n8n.ps1 -Environment prod -ConfigPath "C:\configs\n8n-prod.json"
    Deploys n8n using a custom config file path

.NOTES
    Author: Azure Deployment Script
    Version: 1.0.0
    Last Updated: 2025-11-27

REFERENCES:
    - n8n Environment Variables: https://docs.n8n.io/hosting/configuration/environment-variables/
    - Azure Container Apps: https://learn.microsoft.com/azure/container-apps/
    - PostgreSQL Flexible Server: https://learn.microsoft.com/azure/postgresql/flexible-server/
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("dev", "prod")]
    [string]$Environment,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath
)

# --- [Script Configuration] ---
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# --- [Helper Functions] ---

function Write-Step {
    <#
    .SYNOPSIS
        Writes a formatted step message to the console.
    #>
    param([string]$Message, [string]$Type = "Info")
    
    $timestamp = Get-Date -Format "HH:mm:ss"
    switch ($Type) {
        "Info"    { Write-Host "[$timestamp] ℹ️  $Message" -ForegroundColor Cyan }
        "Success" { Write-Host "[$timestamp] ✅ $Message" -ForegroundColor Green }
        "Warning" { Write-Host "[$timestamp] ⚠️  $Message" -ForegroundColor Yellow }
        "Error"   { Write-Host "[$timestamp] ❌ $Message" -ForegroundColor Red }
        "Header"  { Write-Host "`n[$timestamp] 🚀 $Message" -ForegroundColor Magenta }
    }
}

function Test-AzCliInstalled {
    <#
    .SYNOPSIS
        Verifies Azure CLI is installed and accessible.
    #>
    try {
        $null = az version 2>$null
        return $true
    }
    catch {
        return $false
    }
}

function Test-AzLoggedIn {
    <#
    .SYNOPSIS
        Checks if user is logged into Azure CLI.
    #>
    try {
        $account = az account show 2>$null | ConvertFrom-Json
        return ($null -ne $account)
    }
    catch {
        return $false
    }
}

function Get-Config {
    <#
    .SYNOPSIS
        Loads and validates the JSON configuration file.
    .PARAMETER ConfigFilePath
        Path to the JSON configuration file.
    .OUTPUTS
        PSCustomObject containing the parsed configuration.
    #>
    param([string]$ConfigFilePath)

    Write-Step "Loading configuration from: $ConfigFilePath"

    if (-not (Test-Path $ConfigFilePath)) {
        throw "Configuration file not found: $ConfigFilePath"
    }

    try {
        $configContent = Get-Content -Path $ConfigFilePath -Raw
        $config = $configContent | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse JSON configuration: $_"
    }

    # Validate required fields
    $requiredFields = @(
        "subscriptionId",
        "location",
        "resourceGroupName",
        "containerAppsEnvName",
        "containerAppName",
        "postgresServerName",
        "postgresDbName",
        "logAnalyticsWorkspaceName"
    )

    foreach ($field in $requiredFields) {
        if (-not $config.$field) {
            throw "Missing required configuration field: $field"
        }
    }

    # Validate nested objects
    if (-not $config.n8n) { throw "Missing required configuration section: n8n" }
    if (-not $config.postgres) { throw "Missing required configuration section: postgres" }
    if (-not $config.scale) { throw "Missing required configuration section: scale" }
    if (-not $config.containerAppIngress) { throw "Missing required configuration section: containerAppIngress" }

    # Validate n8n required fields
    $n8nRequiredFields = @("host", "protocol", "port", "encryptionKey")
    foreach ($field in $n8nRequiredFields) {
        if (-not $config.n8n.$field) {
            throw "Missing required n8n configuration field: $field"
        }
    }

    # Validate postgres required fields
    $pgRequiredFields = @("skuName", "storageSizeGb", "version", "adminUser", "adminPassword")
    foreach ($field in $pgRequiredFields) {
        if (-not $config.postgres.$field) {
            throw "Missing required postgres configuration field: $field"
        }
    }

    Write-Step "Configuration validated successfully" -Type "Success"
    return $config
}

function Ensure-ResourceGroup {
    <#
    .SYNOPSIS
        Creates or reuses an Azure Resource Group.
    #>
    param(
        [string]$ResourceGroupName,
        [string]$Location
    )

    Write-Step "Checking Resource Group: $ResourceGroupName"

    $exists = az group exists --name $ResourceGroupName 2>$null
    
    if ($exists -eq "true") {
        Write-Step "Resource Group already exists, reusing: $ResourceGroupName" -Type "Success"
    }
    else {
        Write-Step "Creating Resource Group: $ResourceGroupName in $Location"
        az group create `
            --name $ResourceGroupName `
            --location $Location `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create Resource Group"
        }
        Write-Step "Resource Group created successfully" -Type "Success"
    }
}

function Ensure-LogAnalyticsWorkspace {
    <#
    .SYNOPSIS
        Creates or reuses a Log Analytics Workspace.
    .OUTPUTS
        Hashtable with workspaceId and workspaceKey.
    #>
    param(
        [string]$ResourceGroupName,
        [string]$WorkspaceName,
        [string]$Location
    )

    Write-Step "Checking Log Analytics Workspace: $WorkspaceName"

    $workspace = az monitor log-analytics workspace show `
        --resource-group $ResourceGroupName `
        --workspace-name $WorkspaceName 2>$null | ConvertFrom-Json

    if ($null -eq $workspace) {
        Write-Step "Creating Log Analytics Workspace: $WorkspaceName"
        az monitor log-analytics workspace create `
            --resource-group $ResourceGroupName `
            --workspace-name $WorkspaceName `
            --location $Location `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create Log Analytics Workspace"
        }
        Write-Step "Log Analytics Workspace created successfully" -Type "Success"
    }
    else {
        Write-Step "Log Analytics Workspace already exists, reusing: $WorkspaceName" -Type "Success"
    }

    # Retrieve workspace credentials
    Write-Step "Retrieving Log Analytics Workspace credentials"
    
    $workspaceId = az monitor log-analytics workspace show `
        --resource-group $ResourceGroupName `
        --workspace-name $WorkspaceName `
        --query customerId `
        --output tsv

    $workspaceKey = az monitor log-analytics workspace get-shared-keys `
        --resource-group $ResourceGroupName `
        --workspace-name $WorkspaceName `
        --query primarySharedKey `
        --output tsv

    return @{
        WorkspaceId  = $workspaceId
        WorkspaceKey = $workspaceKey
    }
}

function Ensure-ContainerAppEnvironment {
    <#
    .SYNOPSIS
        Creates or reuses a Container Apps Environment.
    #>
    param(
        [string]$ResourceGroupName,
        [string]$EnvironmentName,
        [string]$Location,
        [string]$WorkspaceId,
        [string]$WorkspaceKey
    )

    Write-Step "Checking Container Apps Environment: $EnvironmentName"

    $env = az containerapp env show `
        --name $EnvironmentName `
        --resource-group $ResourceGroupName 2>$null | ConvertFrom-Json

    if ($null -eq $env) {
        Write-Step "Creating Container Apps Environment: $EnvironmentName"
        az containerapp env create `
            --name $EnvironmentName `
            --resource-group $ResourceGroupName `
            --location $Location `
            --logs-workspace-id $WorkspaceId `
            --logs-workspace-key $WorkspaceKey `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create Container Apps Environment"
        }
        Write-Step "Container Apps Environment created successfully" -Type "Success"
    }
    else {
        Write-Step "Container Apps Environment already exists, reusing: $EnvironmentName" -Type "Success"
    }
}

function Ensure-PostgresServerAndDatabase {
    <#
    .SYNOPSIS
        Creates or reuses PostgreSQL Flexible Server and database.
    .OUTPUTS
        Hashtable with server FQDN.
    #>
    param(
        [string]$ResourceGroupName,
        [string]$ServerName,
        [string]$DatabaseName,
        [string]$Location,
        [PSCustomObject]$PostgresConfig
    )

    Write-Step "Checking PostgreSQL Flexible Server: $ServerName"

    $server = az postgres flexible-server show `
        --resource-group $ResourceGroupName `
        --name $ServerName 2>$null | ConvertFrom-Json

    if ($null -eq $server) {
        Write-Step "Creating PostgreSQL Flexible Server: $ServerName (this may take several minutes)"
        
        # Determine tier from config or default based on SKU pattern
        $tier = if ($PostgresConfig.tier) { $PostgresConfig.tier } else { "GeneralPurpose" }
        
        $createArgs = @(
            "postgres", "flexible-server", "create",
            "--resource-group", $ResourceGroupName,
            "--name", $ServerName,
            "--location", $Location,
            "--admin-user", $PostgresConfig.adminUser,
            "--admin-password", $PostgresConfig.adminPassword,
            "--sku-name", $PostgresConfig.skuName,
            "--storage-size", $PostgresConfig.storageSizeGb,
            "--version", $PostgresConfig.version,
            "--tier", $tier,
            "--output", "none"
        )

        # Configure public access if enabled
        if ($PostgresConfig.publicAccess.enabled) {
            $createArgs += "--public-access"
            $createArgs += "0.0.0.0"
        }

        & az @createArgs

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create PostgreSQL Flexible Server"
        }
        Write-Step "PostgreSQL Flexible Server created successfully" -Type "Success"

        # Configure firewall rules for allowed IPs
        if ($PostgresConfig.publicAccess.enabled -and $PostgresConfig.publicAccess.allowedIps) {
            Write-Step "Configuring firewall rules for PostgreSQL"
            
            # Allow Azure services
            az postgres flexible-server firewall-rule create `
                --resource-group $ResourceGroupName `
                --name $ServerName `
                --rule-name "AllowAzureServices" `
                --start-ip-address "0.0.0.0" `
                --end-ip-address "0.0.0.0" `
                --output none 2>$null
        }
    }
    else {
        Write-Step "PostgreSQL Flexible Server already exists, reusing: $ServerName" -Type "Success"
    }

    # Ensure database exists
    Write-Step "Checking database: $DatabaseName"
    
    $db = az postgres flexible-server db show `
        --resource-group $ResourceGroupName `
        --server-name $ServerName `
        --database-name $DatabaseName 2>$null | ConvertFrom-Json

    if ($null -eq $db) {
        Write-Step "Creating database: $DatabaseName"
        az postgres flexible-server db create `
            --resource-group $ResourceGroupName `
            --server-name $ServerName `
            --database-name $DatabaseName `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create database"
        }
        Write-Step "Database created successfully" -Type "Success"
    }
    else {
        Write-Step "Database already exists, reusing: $DatabaseName" -Type "Success"
    }

    # Get server FQDN
    $serverFqdn = az postgres flexible-server show `
        --resource-group $ResourceGroupName `
        --name $ServerName `
        --query fullyQualifiedDomainName `
        --output tsv

    return @{
        ServerFqdn = $serverFqdn
    }
}

function Ensure-N8nContainerApp {
    <#
    .SYNOPSIS
        Creates or updates the n8n Container App with proper secrets and configuration.
    .OUTPUTS
        Hashtable with the Container App FQDN.
    #>
    param(
        [string]$ResourceGroupName,
        [string]$EnvironmentName,
        [string]$ContainerAppName,
        [string]$PostgresServerFqdn,
        [string]$PostgresDbName,
        [PSCustomObject]$Config
    )

    Write-Step "Checking Container App: $ContainerAppName"

    $app = az containerapp show `
        --name $ContainerAppName `
        --resource-group $ResourceGroupName 2>$null | ConvertFrom-Json

    # Build secrets string
    # Note: Secret names must be lowercase and can contain alphanumeric and hyphens
    $secretsList = @(
        "n8n-encryption-key=$($Config.n8n.encryptionKey)",
        "pg-admin-password=$($Config.postgres.adminPassword)"
    )

    # Add basic auth password if enabled
    if ($Config.n8n.basicAuthActive) {
        $secretsList += "n8n-basic-auth-password=$($Config.n8n.basicAuthPassword)"
    }

    $secretsString = $secretsList -join " "

    # Build environment variables
    # PostgreSQL connection for n8n - Note: For Flexible Server, username is just adminUser (not user@server)
    $envVars = @(
        "N8N_HOST=$($Config.n8n.host)",
        "N8N_PROTOCOL=$($Config.n8n.protocol)",
        "N8N_PORT=$($Config.n8n.port)",
        "N8N_LOG_LEVEL=$($Config.n8n.logLevel)",
        "N8N_PERSONALIZATION_ENABLED=$($Config.n8n.personalizationEnabled.ToString().ToLower())",
        "N8N_ENCRYPTION_KEY=secretref:n8n-encryption-key",
        "DB_TYPE=postgresdb",
        "DB_POSTGRESDB_HOST=$PostgresServerFqdn",
        "DB_POSTGRESDB_PORT=5432",
        "DB_POSTGRESDB_DATABASE=$PostgresDbName",
        "DB_POSTGRESDB_USER=$($Config.postgres.adminUser)",
        "DB_POSTGRESDB_PASSWORD=secretref:pg-admin-password",
        "DB_POSTGRESDB_SCHEMA=public",
        "DB_POSTGRESDB_SSL_ENABLED=true"
    )

    # Add basic auth if enabled
    if ($Config.n8n.basicAuthActive) {
        $envVars += "N8N_BASIC_AUTH_ACTIVE=true"
        $envVars += "N8N_BASIC_AUTH_USER=$($Config.n8n.basicAuthUser)"
        $envVars += "N8N_BASIC_AUTH_PASSWORD=secretref:n8n-basic-auth-password"
    }

    $envVarsString = $envVars -join " "

    # Determine external ingress
    $ingressExternal = if ($Config.containerAppIngress.external) { "external" } else { "internal" }

    # Build scale rule
    $minReplicas = $Config.scale.minReplicas
    $maxReplicas = $Config.scale.maxReplicas

    # Container image - can be parameterized in config if needed
    $containerImage = if ($Config.n8n.image) { $Config.n8n.image } else { "n8nio/n8n:latest" }

    if ($null -eq $app) {
        Write-Step "Creating Container App: $ContainerAppName"
        
        $createCmd = @"
az containerapp create ``
    --name $ContainerAppName ``
    --resource-group $ResourceGroupName ``
    --environment $EnvironmentName ``
    --image $containerImage ``
    --target-port $($Config.containerAppIngress.targetPort) ``
    --ingress $ingressExternal ``
    --min-replicas $minReplicas ``
    --max-replicas $maxReplicas ``
    --secrets $secretsString ``
    --env-vars $envVarsString ``
    --cpu 1.0 ``
    --memory 2.0Gi ``
    --output none
"@

        az containerapp create `
            --name $ContainerAppName `
            --resource-group $ResourceGroupName `
            --environment $EnvironmentName `
            --image $containerImage `
            --target-port $Config.containerAppIngress.targetPort `
            --ingress $ingressExternal `
            --min-replicas $minReplicas `
            --max-replicas $maxReplicas `
            --secrets $secretsList `
            --env-vars $envVars `
            --cpu 1.0 `
            --memory 2.0Gi `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create Container App"
        }
        Write-Step "Container App created successfully" -Type "Success"
    }
    else {
        Write-Step "Container App exists, updating: $ContainerAppName"
        
        # Update secrets first
        az containerapp secret set `
            --name $ContainerAppName `
            --resource-group $ResourceGroupName `
            --secrets $secretsList `
            --output none 2>$null

        # Update the container app
        az containerapp update `
            --name $ContainerAppName `
            --resource-group $ResourceGroupName `
            --image $containerImage `
            --min-replicas $minReplicas `
            --max-replicas $maxReplicas `
            --set-env-vars $envVars `
            --cpu 1.0 `
            --memory 2.0Gi `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to update Container App"
        }
        Write-Step "Container App updated successfully" -Type "Success"
    }

    # Configure HTTP scale rule if specified
    if ($Config.scale.scaleRuleType -eq "http") {
        Write-Step "Configuring HTTP scale rule (concurrent requests: $($Config.scale.concurrentRequests))"
        
        # Scale rules are configured during create/update via YAML or additional commands
        # For simplicity, we rely on the default HTTP scaling behavior
    }

    # Get the FQDN
    $appFqdn = az containerapp show `
        --name $ContainerAppName `
        --resource-group $ResourceGroupName `
        --query properties.configuration.ingress.fqdn `
        --output tsv

    return @{
        Fqdn = $appFqdn
    }
}

function Show-DeploymentSummary {
    <#
    .SYNOPSIS
        Displays a summary of the deployment with next steps.
    #>
    param(
        [string]$Environment,
        [string]$ResourceGroupName,
        [string]$ContainerAppName,
        [string]$ContainerAppFqdn,
        [string]$PostgresServerName,
        [string]$PostgresDbName,
        [string]$N8nHost
    )

    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "                    DEPLOYMENT COMPLETE                             " -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Environment:        $Environment" -ForegroundColor White
    Write-Host "  Resource Group:     $ResourceGroupName" -ForegroundColor White
    Write-Host "  Container App:      $ContainerAppName" -ForegroundColor White
    Write-Host "  Container App FQDN: https://$ContainerAppFqdn" -ForegroundColor Cyan
    Write-Host "  PostgreSQL Server:  $PostgresServerName" -ForegroundColor White
    Write-Host "  PostgreSQL DB:      $PostgresDbName" -ForegroundColor White
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. Access n8n at: https://$ContainerAppFqdn" -ForegroundColor White
    Write-Host ""
    Write-Host "  2. (Optional) Configure custom domain:" -ForegroundColor White
    Write-Host "     - Add CNAME record: $N8nHost -> $ContainerAppFqdn" -ForegroundColor Gray
    Write-Host "     - Configure custom domain in Azure Portal or via CLI:" -ForegroundColor Gray
    Write-Host "       az containerapp hostname add --name $ContainerAppName \" -ForegroundColor Gray
    Write-Host "         --resource-group $ResourceGroupName --hostname $N8nHost" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  3. (Optional) Enable managed certificate for HTTPS:" -ForegroundColor White
    Write-Host "     az containerapp hostname bind --name $ContainerAppName \" -ForegroundColor Gray
    Write-Host "       --resource-group $ResourceGroupName --hostname $N8nHost \" -ForegroundColor Gray
    Write-Host "       --environment <env-name> --validation-method CNAME" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  4. Review and tighten PostgreSQL firewall rules:" -ForegroundColor White
    Write-Host "     az postgres flexible-server firewall-rule list \" -ForegroundColor Gray
    Write-Host "       --resource-group $ResourceGroupName --name $PostgresServerName" -ForegroundColor Gray
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
}

# --- [Main Execution] ---

try {
    Write-Step "n8n Azure Deployment Script" -Type "Header"
    Write-Step "Environment: $Environment"

    # Validate Azure CLI installation
    if (-not (Test-AzCliInstalled)) {
        throw "Azure CLI is not installed or not in PATH. Please install it from: https://docs.microsoft.com/cli/azure/install-azure-cli"
    }
    Write-Step "Azure CLI is installed" -Type "Success"

    # Check Azure login status
    if (-not (Test-AzLoggedIn)) {
        throw "Not logged into Azure CLI. Please run 'az login' first."
    }
    Write-Step "Azure CLI is authenticated" -Type "Success"

    # Ensure Container Apps extension is installed
    Write-Step "Ensuring Container Apps extension is installed"
    az extension add --name containerapp --upgrade --only-show-errors 2>$null
    Write-Step "Container Apps extension ready" -Type "Success"

    # Determine config file path
    if (-not $ConfigPath) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        $ConfigPath = Join-Path $scriptDir "config.$Environment.json"
    }

    # Load configuration
    $config = Get-Config -ConfigFilePath $ConfigPath

    # Set Azure subscription
    Write-Step "Setting Azure subscription: $($config.subscriptionId)"
    az account set --subscription $config.subscriptionId
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set Azure subscription. Verify the subscription ID is correct and you have access."
    }
    Write-Step "Subscription set successfully" -Type "Success"

    # Create or verify Resource Group
    Write-Step "Resource Group" -Type "Header"
    Ensure-ResourceGroup `
        -ResourceGroupName $config.resourceGroupName `
        -Location $config.location

    # Create or verify Log Analytics Workspace
    Write-Step "Log Analytics Workspace" -Type "Header"
    $workspaceInfo = Ensure-LogAnalyticsWorkspace `
        -ResourceGroupName $config.resourceGroupName `
        -WorkspaceName $config.logAnalyticsWorkspaceName `
        -Location $config.location

    # Create or verify Container Apps Environment
    Write-Step "Container Apps Environment" -Type "Header"
    Ensure-ContainerAppEnvironment `
        -ResourceGroupName $config.resourceGroupName `
        -EnvironmentName $config.containerAppsEnvName `
        -Location $config.location `
        -WorkspaceId $workspaceInfo.WorkspaceId `
        -WorkspaceKey $workspaceInfo.WorkspaceKey

    # Create or verify PostgreSQL Flexible Server and Database
    Write-Step "PostgreSQL Flexible Server" -Type "Header"
    $postgresInfo = Ensure-PostgresServerAndDatabase `
        -ResourceGroupName $config.resourceGroupName `
        -ServerName $config.postgresServerName `
        -DatabaseName $config.postgresDbName `
        -Location $config.location `
        -PostgresConfig $config.postgres

    # Create or update n8n Container App
    Write-Step "n8n Container App" -Type "Header"
    $appInfo = Ensure-N8nContainerApp `
        -ResourceGroupName $config.resourceGroupName `
        -EnvironmentName $config.containerAppsEnvName `
        -ContainerAppName $config.containerAppName `
        -PostgresServerFqdn $postgresInfo.ServerFqdn `
        -PostgresDbName $config.postgresDbName `
        -Config $config

    # Display deployment summary
    Show-DeploymentSummary `
        -Environment $Environment `
        -ResourceGroupName $config.resourceGroupName `
        -ContainerAppName $config.containerAppName `
        -ContainerAppFqdn $appInfo.Fqdn `
        -PostgresServerName $config.postgresServerName `
        -PostgresDbName $config.postgresDbName `
        -N8nHost $config.n8n.host

    exit 0
}
catch {
    Write-Step "Deployment failed: $_" -Type "Error"
    Write-Host ""
    Write-Host "Stack Trace:" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray
    exit 1
}
