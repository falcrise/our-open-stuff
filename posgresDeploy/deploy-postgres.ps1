<#
.SYNOPSIS
    Deploys a standalone Azure Database for PostgreSQL Flexible Server.

.DESCRIPTION
    This script provisions:
    - Azure Resource Group
    - PostgreSQL Flexible Server with database(s)
    - Firewall rules for access control

    The script is idempotent: existing resources are reused/updated rather than recreated.

.PREREQUISITES
    1. Azure CLI installed: https://docs.microsoft.com/cli/azure/install-azure-cli
    2. Logged into Azure: az login
    3. Appropriate subscription permissions

.PARAMETER Environment
    Required. Specifies the target environment: 'dev' or 'prod'.
    Maps to config.dev.json or config.prod.json respectively.

.PARAMETER ConfigPath
    Optional. Override the default config file path.
    Defaults to .\config.<Environment>.json

.EXAMPLE
    .\deploy-postgres.ps1 -Environment dev
    Deploys PostgreSQL using config.dev.json

.EXAMPLE
    .\deploy-postgres.ps1 -Environment prod -ConfigPath "C:\configs\pg-prod.json"
    Deploys PostgreSQL using a custom config file path

.NOTES
    Author: Azure Deployment Script
    Version: 1.0.0
    Last Updated: 2025-11-27

REFERENCES:
    - PostgreSQL Flexible Server: https://learn.microsoft.com/azure/postgresql/flexible-server/
    - Azure CLI postgres commands: https://learn.microsoft.com/cli/azure/postgres/flexible-server
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
    try {
        $null = az version 2>$null
        return $true
    }
    catch {
        return $false
    }
}

function Test-AzLoggedIn {
    try {
        $account = az account show 2>$null | ConvertFrom-Json
        return ($null -ne $account)
    }
    catch {
        return $false
    }
}

function Get-Config {
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
        "postgresServerName"
    )

    foreach ($field in $requiredFields) {
        if (-not $config.$field) {
            throw "Missing required configuration field: $field"
        }
    }

    # Validate postgres section
    if (-not $config.postgres) { throw "Missing required configuration section: postgres" }

    $pgRequiredFields = @("skuName", "tier", "storageSizeGb", "version", "adminUser", "adminPassword")
    foreach ($field in $pgRequiredFields) {
        if (-not $config.postgres.$field) {
            throw "Missing required postgres configuration field: $field"
        }
    }

    Write-Step "Configuration validated successfully" -Type "Success"
    return $config
}

function Ensure-ResourceGroup {
    param(
        [string]$ResourceGroupName,
        [string]$Location,
        [hashtable]$Tags
    )

    Write-Step "Checking Resource Group: $ResourceGroupName"

    $exists = az group exists --name $ResourceGroupName 2>$null
    
    if ($exists -eq "true") {
        Write-Step "Resource Group already exists, reusing: $ResourceGroupName" -Type "Success"
    }
    else {
        Write-Step "Creating Resource Group: $ResourceGroupName in $Location"
        
        $tagArgs = @()
        if ($Tags -and $Tags.Count -gt 0) {
            $tagStrings = $Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
            $tagArgs = @("--tags") + $tagStrings
        }

        az group create `
            --name $ResourceGroupName `
            --location $Location `
            @tagArgs `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create Resource Group"
        }
        Write-Step "Resource Group created successfully" -Type "Success"
    }
}

function Ensure-PostgresServer {
    param(
        [string]$ResourceGroupName,
        [string]$ServerName,
        [string]$Location,
        [PSCustomObject]$PostgresConfig
    )

    Write-Step "Checking PostgreSQL Flexible Server: $ServerName"

    $server = az postgres flexible-server show `
        --resource-group $ResourceGroupName `
        --name $ServerName 2>$null | ConvertFrom-Json

    if ($null -eq $server) {
        Write-Step "Creating PostgreSQL Flexible Server: $ServerName (this may take several minutes)"
        
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

        # Add high availability if configured
        if ($PostgresConfig.highAvailability -and $PostgresConfig.highAvailability.enabled) {
            $createArgs += "--high-availability"
            $createArgs += "Enabled"
            if ($PostgresConfig.highAvailability.mode) {
                $createArgs += "--high-availability-mode"
                $createArgs += $PostgresConfig.highAvailability.mode
            }
        }

        # Add backup retention if configured
        if ($PostgresConfig.backupRetentionDays) {
            $createArgs += "--backup-retention"
            $createArgs += $PostgresConfig.backupRetentionDays
        }

        & az @createArgs

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create PostgreSQL Flexible Server"
        }
        Write-Step "PostgreSQL Flexible Server created successfully" -Type "Success"
    }
    else {
        Write-Step "PostgreSQL Flexible Server already exists, reusing: $ServerName" -Type "Success"
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

function Ensure-FirewallRules {
    param(
        [string]$ResourceGroupName,
        [string]$ServerName,
        [PSCustomObject]$PublicAccessConfig
    )

    if (-not $PublicAccessConfig.enabled) {
        Write-Step "Public access is disabled, skipping firewall rules" -Type "Warning"
        return
    }

    Write-Step "Configuring firewall rules for PostgreSQL"

    # Allow Azure services
    $existingRule = az postgres flexible-server firewall-rule show `
        --resource-group $ResourceGroupName `
        --name $ServerName `
        --rule-name "AllowAzureServices" 2>$null | ConvertFrom-Json

    if ($null -eq $existingRule) {
        az postgres flexible-server firewall-rule create `
            --resource-group $ResourceGroupName `
            --name $ServerName `
            --rule-name "AllowAzureServices" `
            --start-ip-address "0.0.0.0" `
            --end-ip-address "0.0.0.0" `
            --output none

        Write-Step "Created firewall rule: AllowAzureServices" -Type "Success"
    }
    else {
        Write-Step "Firewall rule AllowAzureServices already exists" -Type "Success"
    }

    # Add custom IP rules if specified
    if ($PublicAccessConfig.firewallRules) {
        foreach ($rule in $PublicAccessConfig.firewallRules) {
            $existingCustomRule = az postgres flexible-server firewall-rule show `
                --resource-group $ResourceGroupName `
                --name $ServerName `
                --rule-name $rule.name 2>$null | ConvertFrom-Json

            if ($null -eq $existingCustomRule) {
                az postgres flexible-server firewall-rule create `
                    --resource-group $ResourceGroupName `
                    --name $ServerName `
                    --rule-name $rule.name `
                    --start-ip-address $rule.startIp `
                    --end-ip-address $rule.endIp `
                    --output none

                Write-Step "Created firewall rule: $($rule.name)" -Type "Success"
            }
            else {
                Write-Step "Firewall rule $($rule.name) already exists" -Type "Success"
            }
        }
    }
}

function Ensure-Databases {
    param(
        [string]$ResourceGroupName,
        [string]$ServerName,
        [array]$Databases
    )

    if (-not $Databases -or $Databases.Count -eq 0) {
        Write-Step "No databases specified in configuration" -Type "Warning"
        return
    }

    foreach ($dbName in $Databases) {
        Write-Step "Checking database: $dbName"
        
        $db = az postgres flexible-server db show `
            --resource-group $ResourceGroupName `
            --server-name $ServerName `
            --database-name $dbName 2>$null | ConvertFrom-Json

        if ($null -eq $db) {
            Write-Step "Creating database: $dbName"
            az postgres flexible-server db create `
                --resource-group $ResourceGroupName `
                --server-name $ServerName `
                --database-name $dbName `
                --output none

            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create database: $dbName"
            }
            Write-Step "Database created successfully: $dbName" -Type "Success"
        }
        else {
            Write-Step "Database already exists, reusing: $dbName" -Type "Success"
        }
    }
}

function Show-DeploymentSummary {
    param(
        [string]$Environment,
        [string]$ResourceGroupName,
        [string]$PostgresServerName,
        [string]$PostgresServerFqdn,
        [array]$Databases,
        [string]$AdminUser
    )

    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "                    DEPLOYMENT COMPLETE                             " -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Environment:        $Environment" -ForegroundColor White
    Write-Host "  Resource Group:     $ResourceGroupName" -ForegroundColor White
    Write-Host "  PostgreSQL Server:  $PostgresServerName" -ForegroundColor White
    Write-Host "  Server FQDN:        $PostgresServerFqdn" -ForegroundColor Cyan
    Write-Host "  Admin User:         $AdminUser" -ForegroundColor White
    Write-Host "  Databases:          $($Databases -join ', ')" -ForegroundColor White
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "  CONNECTION STRING TEMPLATE:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Host:     $PostgresServerFqdn" -ForegroundColor Gray
    Write-Host "  Port:     5432" -ForegroundColor Gray
    Write-Host "  User:     $AdminUser" -ForegroundColor Gray
    Write-Host "  SSL Mode: require" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  psql \"host=$PostgresServerFqdn port=5432 dbname=$($Databases[0]) user=$AdminUser sslmode=require\"" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. Review and tighten firewall rules:" -ForegroundColor White
    Write-Host "     az postgres flexible-server firewall-rule list \" -ForegroundColor Gray
    Write-Host "       --resource-group $ResourceGroupName --name $PostgresServerName" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2. Consider enabling Private Endpoints for production use" -ForegroundColor White
    Write-Host ""
    Write-Host "  3. Set up monitoring and alerts in Azure Portal" -ForegroundColor White
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
}

# --- [Main Execution] ---

try {
    Write-Step "PostgreSQL Azure Deployment Script" -Type "Header"
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

    # Convert tags to hashtable if present
    $tags = @{}
    if ($config.tags) {
        $config.tags.PSObject.Properties | ForEach-Object {
            $tags[$_.Name] = $_.Value
        }
    }

    # Create or verify Resource Group
    Write-Step "Resource Group" -Type "Header"
    Ensure-ResourceGroup `
        -ResourceGroupName $config.resourceGroupName `
        -Location $config.location `
        -Tags $tags

    # Create or verify PostgreSQL Flexible Server
    Write-Step "PostgreSQL Flexible Server" -Type "Header"
    $postgresInfo = Ensure-PostgresServer `
        -ResourceGroupName $config.resourceGroupName `
        -ServerName $config.postgresServerName `
        -Location $config.location `
        -PostgresConfig $config.postgres

    # Configure firewall rules
    Write-Step "Firewall Rules" -Type "Header"
    Ensure-FirewallRules `
        -ResourceGroupName $config.resourceGroupName `
        -ServerName $config.postgresServerName `
        -PublicAccessConfig $config.postgres.publicAccess

    # Create databases
    Write-Step "Databases" -Type "Header"
    Ensure-Databases `
        -ResourceGroupName $config.resourceGroupName `
        -ServerName $config.postgresServerName `
        -Databases $config.databases

    # Display deployment summary
    Show-DeploymentSummary `
        -Environment $Environment `
        -ResourceGroupName $config.resourceGroupName `
        -PostgresServerName $config.postgresServerName `
        -PostgresServerFqdn $postgresInfo.ServerFqdn `
        -Databases $config.databases `
        -AdminUser $config.postgres.adminUser

    exit 0
}
catch {
    Write-Step "Deployment failed: $_" -Type "Error"
    Write-Host ""
    Write-Host "Stack Trace:" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray
    exit 1
}
