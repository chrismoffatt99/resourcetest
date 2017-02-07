#Requires -Version 3.0

<#
.SYNOPSIS
    Deploys a copy of the Ed-Fi ODS to an Azure account
.DESCRIPTION
    Deploys a copy of the Ed-Fi ODS to an Azure account
.PARAMETER Version
    Version of the Ed-Fi ODS you want to deploy.  Valid version numbers are published in Ed-Fi TechDocs.
.PARAMETER ResourceGroupLocation
    The name of the Azure region where all resources will be provisioned (see https://azure.microsoft.com/en-us/regions/).  You should try and use a region near you for optimal performance.
.PARAMETER InstallFriendlyName
    A friendly name to help identify this instance of the Ed-Fi ODS within Azure.  Must be no more than 64 characters long
.PARAMETER UseMyOwnSqlServer
    If provided, the script will not provision databases for you in Azure SQL.  Instead, you'll be required to provided connection info to your own SQL Server already configured with ODS Databases.
.PARAMETER TemplateFileDirectory
    Points the script to the directory that holds the Ed-Fi ODS install templates.  By default that directory is the same as the one that contains this script.
.EXAMPLE
    .\Deploy-EdFiOds.ps1 -ResourceGroupLocation "South Central US"
    Deploys the latest version of the Ed-Fi ODS (including the config tool website) to the South Central US Azure region with the default instance name
.EXAMPLE
    .\Deploy-EdFiOds.ps1 -Version "1.0" -ResourceGroupLocation "South Central US" -InstallFriendlyName "EdFi ODS"
    Deploys v1.0 of the Ed-Fi ODS (including the config tool website) to the South Central US Azure region and names it "EdFi ODS"
.EXAMPLE
    .\Deploy-EdFiOds.ps1 -Version "1.0" -ResourceGroupLocation "South Central US" -UseMyOwnSqlServer
    Deploys v1.0 of the Ed-Fi ODS to the South Central US Azure region and gathers connection info for a SQL Server where you've already deployed Ed-Fi ODS databases.
#>
Param(
	[string] 
	[Parameter(Mandatory=$false)]
	$ResourceGroupLocation,

	[string]
	[Parameter(Mandatory=$false)]
	$Version,

	[ValidatePattern('^[a-zA-z0-9\s-]+$')]
	[ValidateLength(1,64)]
	[string] 
	[Parameter(Mandatory=$false)] 
	$InstallFriendlyName = 'EdFi ODS',

	[string] 
	[Parameter(Mandatory=$false)] 
	$TemplateFileDirectory = '.\',

	[switch] 
	$UseMyOwnSqlServer,

	[string]
	[ValidateSet('release','test')]
	$Edition = 'release'
)

$DoNotInstallAdminApp = $false

$OdsTemplateFile = "$TemplateFileDirectory\Ods.json"
$OdsTemplateParametersFile = "$TemplateFileDirectory\Ods.parameters.json"
$OdsWithoutSqlServerTemplateFile = "$TemplateFileDirectory\OdsWithoutSqlServer.json"
$OdsWithoutSqlServerTemplateParametersFile = "$TemplateFileDirectory\OdsWithoutSqlServer.parameters.json"

$AdminAppTemplateFile = "$TemplateFileDirectory\OdsAdminApp.json"
$AdminAppTemplateParametersFile = "$TemplateFileDirectory\OdsAdminApp.parameters.json"
$AdminAppWithoutSqlServerTemplateFile = "$TemplateFileDirectory\OdsAdminAppWithoutSqlServer.json"
$AdminAppWithoutSqlServerTemplateParametersFile = "$TemplateFileDirectory\OdsAdminAppWithoutSqlServer.parameters.json"

$CloudOdsSqlServerInfoVaultKeyName = "CloudOdsSqlServerInfo"

Import-Module $PSScriptRoot\AzureActiveDirectoryApplicationHelper.psm1 -Force -DisableNameChecking
Import-Module $PSScriptRoot\EdFiOdsDeploy.psm1 -Force -DisableNameChecking

function Get-AdminAppSqlUserCredentials()
{
	if ($DoNotInstallAdminApp)
	{
		return $null
	}

	else
	{
		return Get-SqlUserCredentials "EdFiOdsAdminApp" "Admin App"
	}
}

function Get-AzureSqlServerInfo()
{	
	$title = "Create New SQL Server"
	$messageBody = @"
Please enter a username and password.
Your password must be at least 8 characters long, and contain characters from three of the following categories:  uppercase (A though Z), lowercase (a-z), digits (0-9) and nonalphabetic characters (eg: !, $, #, %).
These credentials will be used to create a new Azure SQL Server for you. Be sure to record these credentials for later use.
"@
	
	$sqlServer = @{
		HostName = ""
		AdminCredentials = (Get-ValidatedCredentials $title $messageBody Get-SqlUsernameErrorMessage Get-AzureSqlPasswordErrorMessage)
		AdminAppCredentials = (Get-AdminAppSqlUserCredentials)
		ProductionApiCredentials = (Get-SqlUserCredentials "EdFiOdsProductionApi" "Production API")
		SandboxApiCredentials = (Get-SqlUserCredentials "EdFiOdsSandboxApi" "Sandbox API")
	}
	
	return $sqlServer
}

function Get-SqlUserCredentials($defaultUsername, $appName)
{
	$prompt = "Please provide credentials for the Ed-Fi ODS $appName"

	if (-not $DoNotInstallAdminApp)
	{
		$defaultPassword = ConvertTo-SecureString (Create-Password) -AsPlainText -Force
		$credential = New-Object -TypeName "System.Management.Automation.PSCredential" -ArgumentList $defaultUsername,$defaultPassword
		
		return $credential
	}

	else
	{
		return Get-CredentialFromConsole $prompt $defaultUsername
	}
}


function Get-SqlServerInfo()
{	
	$hostName = Read-Host -Prompt "SQL Server Hostname (ex: sql.mydomain.com:1433)"
	$adminCredentialsPrompt = "Please enter a username and password for your SQL Server.  These credentials will be used to create new database users for your Ed-Fi ODS installation."

	$sqlServer = @{
		HostName = $hostName
		AdminCredentials = (Get-CredentialFromConsole $adminCredentialsPrompt)
		AdminAppCredentials = (Get-AdminAppSqlUserCredentials)
		ProductionApiCredentials = (Get-SqlUserCredentials "EdFiOdsProductionApi" "Production API")
		SandboxApiCredentials = (Get-SqlUserCredentials "EdFiOdsSandboxApi" "Sandbox API")
	}
	
	return $sqlServer
}

function Rollback-Deployment([string]$resourceGroupName, [string]$deploymentExceptionMessage) {
	Write-Host "The following error occured during deployment:" -ForegroundColor Red
	Write-Host $deploymentExceptionMessage -ForegroundColor Red
	Write-Host "Attempting to roll back.  Please wait..."  -ForegroundColor Red

	Try {
		Delete-ResourceGroup $resourceGroupName
	} Catch {
		$ErrorMessage = $_.Exception.Message
		$ErrorMessage += ([environment]::NewLine)
		$ErrorMessage += "Rollback Error: unable to remove resource group $resourceGroupName.  You should remove this resource group manually in the Azure Portal to avoid incurring extra charges.";
		Write-Error $ErrorMessage
	}

	Try {
		Delete-AzureCloudOdsAdApplication $InstallFriendlyName
	} Catch {
		$ErrorMessage = $_.Exception.Message
		$ErrorMessage += ([environment]::NewLine)
		$ErrorMessage += "Rollback Error: unable to remove application.  You may remove the application manually in the Azure Portal.";
		Write-Error $ErrorMessage
	}

    $deploymentRollbackMessage = @"
An error occured during deployment, and the changes were rolled back.

NOTE:

There may be a delay while Azure processes all rollback actions.
Please wait a few minutes before retrying or deployment may fail.
"@
	Write-Error $deploymentRollbackMessage
}

function Deploy-EdFiOds([string]$resourceGroupName, $sqlServer)
{
	Write-Success "Deploying Ed-Fi Cloud ODS version $Version"
		
	$deployParameters = New-Object -TypeName Hashtable
	$deployParameters.Add("version", $Version)
	$deployParameters.Add("edition", $Edition)
	$deployParameters.Add("appInsightsLocation", $AppInsightsLocation)
	$deployParameters.Add("sqlServerAdminLogin", $sqlServer.AdminCredentials.UserName)
	$deployParameters.Add("sqlServerAdminPassword", $sqlServer.AdminCredentials.Password)

	$deployParameters.Add("sqlServerProductionApiLogin", $sqlServer.ProductionApiCredentials.UserName)
	$deployParameters.Add("sqlServerProductionApiPassword", $sqlServer.ProductionApiCredentials.Password)
	$deployParameters.Add("sqlServerSandboxApiLogin", $sqlServer.SandboxApiCredentials.UserName)
	$deployParameters.Add("sqlServerSandboxApiPassword", $sqlServer.SandboxApiCredentials.Password)
		
	if ($UseMyOwnSqlServer)
	{
		$deployParameters.Add("sqlServerHostName", $sqlServer.HostName)

		$templateFile = $OdsWithoutSqlServerTemplateFile
		$templateParametersFile = $OdsWithoutSqlServerTemplateParametersFile
	}

	else
	{
		$templateFile = $OdsTemplateFile
		$templateParametersFile = $OdsTemplateParametersFile
	}
		
    Try
    {
	$deploymentResult = New-AzureRmResourceGroupDeployment -Name ((Get-ChildItem $templateFile).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
                                   -ResourceGroupName $resourceGroupName `
                                   -TemplateFile $templateFile `
                                   -TemplateParameterFile $templateParametersFile `
                                   @deployParameters `
                                   -Force -Verbose -ErrorAction Stop
    }
    Catch
    {
        Rollback-Deployment $resourceGroupName $_.Exception.Message
    }

	if ($deploymentResult.Outputs.ContainsKey('swaggerUrl'))
	{
		$swaggerUrl = $deploymentResult.Outputs.swaggerUrl.Value;
		Write-Success "Ed-Fi ODS SwaggerUI (documentation) accessible at $swaggerUrl"
	}

	return $deploymentResult
}

function Add-SqlInfoToKeyVault($keyVault, $sqlServerInfo)
{    
	$sqlServerInfoAsPlainText = @{
		HostName = $sqlServerInfo.HostName
		AdminCredentials = (Get-CredentialAsPlainText $sqlServerInfo.AdminCredentials)
		AdminAppCredentials = (Get-CredentialAsPlainText $sqlServerInfo.AdminAppCredentials)
		ProductionApiCredentials = (Get-CredentialAsPlainText $sqlServerInfo.ProductionApiCredentials)
		SandboxApiCredentials = (Get-CredentialAsPlainText $sqlServerInfo.SandboxApiCredentials)
	}
		
	$jsonSqlServerInfo = ConvertTo-Json $sqlServerInfoAsPlainText
	$sqlServerInfoForVault = ConvertTo-SecureString $jsonSqlServerInfo -AsPlainText -Force	

	$secret = Set-AzureKeyVaultSecret -VaultName $keyVault.VaultName -Name $CloudOdsSqlServerInfoVaultKeyName -SecretValue $sqlServerInfoForVault
	return $secret
}

function Deploy-AdminApp($odsDeployInfo)
{
	$resourceGroupName = $odsDeployInfo.ResourceGroupName
	$resourceGroupLocation = $odsDeployInfo.ResourceGroupLocation
	$appInsightsLocation = $odsDeployInfo.AppInsightsLocation
	$resourceGroupUniqueId = $odsDeployInfo.ResourceGroupUniqueString
	$sqlServer = $odsDeployInfo.SqlServerInfo
	$sandboxApiUrl = $odsDeployInfo.SandboxApiUrl
	$productionApiUrl = $odsDeployInfo.ProductionApiUrl
	$swaggerUrl = $odsDeployInfo.SwaggerUrl
	
	$deployParameters = New-Object -TypeName Hashtable
	$deployParameters.Add("version", $Version)
	$deployParameters.Add("edition", $Edition)
	$deployParameters.Add("appInsightsLocation", $AppInsightsLocation)
	$deployParameters.Add("odsInstanceName", $InstallFriendlyName)
	$deployParameters.Add("sqlServerAdminLogin", $sqlServer.AdminCredentials.UserName)
	$deployParameters.Add("sqlServerAdminPassword", $sqlServer.AdminCredentials.Password)

	$deployParameters.Add("sqlServerAdminAppLogin", $sqlServer.AdminAppCredentials.UserName)
	$deployParameters.Add("sqlServerAdminAppPassword", $sqlServer.AdminAppCredentials.Password)

	$deployParameters.Add("sandboxApiUrl", $sandboxApiUrl)
	$deployParameters.Add("productionApiUrl", $productionApiUrl)
	$deployParameters.Add("swaggerUrl", $swaggerUrl)
	
	if ($UseMyOwnSqlServer)
	{
		$deployParameters.Add("sqlServerHostName", $sqlServer.HostName)

		$templateFile = $AdminAppWithoutSqlServerTemplateFile
		$templateParametersFile = $AdminAppWithoutSqlServerTemplateParametersFile
	}

	else
	{
		$templateFile = $AdminAppTemplateFile
		$templateParametersFile = $AdminAppTemplateParametersFile
	}

	$adminAppName = "EdFiOdsAdminAppWebSite-Production-$resourceGroupUniqueId"
	$adminAppUrl = "http://$adminAppName.azurewebsites.net";
	$secureAdminAppUrl = "https://$adminAppName.azurewebsites.net";

	$tenantId = (Get-AzureRmContext).Tenant.TenantId
	$subscriptionId = (Get-AzureRmContext).Subscription.SubscriptionId

	$password = [guid]::NewGuid().ToString()

    Try
    {
		Write-Host "Creating Azure AD Application for Ed-Fi ODS Admin App"
		$app = New-AzureCloudOdsAdApplication -DisplayName $InstallFriendlyName -ReplyUrls $adminAppUrl,$secureAdminAppUrl -HomePage $secureAdminAppUrl -IdentifierUris $adminAppUrl -AppSecrets $password -TenantId $tenantId -AppYears 100

		#Wait for a few seconds to allow app creation / service principal to propagate in Azure AD	
		Start-Sleep -Seconds 15

		Write-Host "Granting Azure AD Application contributor access to Resource Group"
		$roleAssignment = New-AzureRmRoleAssignment -ObjectId $app.ServicePrincipal.objectId -ResourceGroupName $resourceGroupName -RoleDefinitionName "Contributor"

		$deployParameters.Add("aadClientId", $app.Application.appId)
		$deployParameters.Add("aadClientSecret", $password)
		$deployParameters.Add("aadTenantId", $tenantId)
		$deployParameters.Add("aadSubscriptionId", $subscriptionId)

		Write-Host "Creating Azure KeyVault"
		$keyVault = Create-KeyVault $resourceGroupName $resourceGroupLocation $resourceGroupUniqueId
		$sqlKeyvaultSecret = Add-SqlInfoToKeyVault $keyVault $sqlServer

		Write-Host "Granting AdminApp access to KeyVault"
		Set-AzureRmKeyVaultAccessPolicy -VaultName $keyVault.VaultName -ServicePrincipalName $app.Application.appId -PermissionsToSecrets Get

		$deployParameters.Add("azureKeyVaultUrl", $keyVault.VaultUri)


		Write-Host "Deploying ODS Admin App"
		
		$deploymentResult = New-AzureRmResourceGroupDeployment -Name ((Get-ChildItem $templateFile).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
									   -ResourceGroupName $resourceGroupName `
									   -TemplateFile $templateFile `
									   -TemplateParameterFile $templateParametersFile `
									   @deployParameters `
									   -Force -Verbose -ErrorAction Stop
    }
    Catch
    {
        Rollback-Deployment $resourceGroupName $_.Exception.Message
    }

	Write-Success "Ed-Fi ODS Admin App accessible at $adminAppUrl"
	
	return $deploymentResult
}

Verify-PowershellCmdletsInstalled
if (-not $Version)
{
	$script:Version = Get-LatestCloudOdsVersion $Edition
}

else
{
	Validate-VersionAndEdition $Version $Edition
}

Login-AzureAccount

if (-not $DoNotInstallAdminApp)
{
	Validate-UserIsAzureGlobalAdmin
}

if (-not $ResourceGroupLocation)
{
	$ResourceGroupLocation = Select-ResourceGroupLocation
	$AppInsightsLocation = Get-NearestAppInsightsLocation $ResourceGroupLocation
}

if ($UseMyOwnSqlServer)
{
	$sqlServerInfo = Get-SqlServerInfo
}

else 
{
	$sqlServerInfo = Get-AzureSqlServerInfo
}

$resourceGroupName = (Create-ResourceGroup $InstallFriendlyName $ResourceGroupLocation $Version $Edition)

if ($DoNotInstallAdminApp)
{
	Write-Warning "*** NOTE ***"
	Write-Warning "Since you are not installing the Ed-Fi ODS Admin App, you'll need to manually"
	Write-Warning "create SQL logins in order for the Ed-Fi ODS to function.  You'll be prompted"
	Write-Warning "for these logins momentarily.  Be sure the logins you enter at these prompts"
	Write-Warning "match what you setup in your SQL Server.  See install documentation for"
	Write-Warning "further details or recommended access rights for each login."
	Write-Warning "***"
	Write-Warning ""
	Read-Host "Press [Enter] to continue"
}

$odsDeploymentResult = Deploy-EdFiOds $resourceGroupName $sqlServerInfo

#deployment result will send back SQL Server host name
$sqlServerInfo.HostName = $odsDeploymentResult.Outputs.sqlServerHostname.Value

if (-not $DoNotInstallAdminApp)
{
	$odsDeployInfo = @{		
		ResourceGroupName = $resourceGroupName
		ResourceGroupLocation = $ResourceGroupLocation
		AppInsightsLocation = $AppInsightsLocation
		ResourceGroupUniqueString = $odsDeploymentResult.Outputs.resourceGroupUniqueString.Value
		SandboxApiUrl = $odsDeploymentResult.Outputs.sandboxApiUrl.Value
		ProductionApiUrl = $odsDeploymentResult.Outputs.productionApiUrl.Value
		SwaggerUrl = $odsDeploymentResult.Outputs.swaggerUrl.Value
		SqlServerInfo = $sqlServerInfo
	};
		
	$adminAppDeploymentResult = Deploy-AdminApp $odsDeployInfo
}

Warmup-Website $odsDeploymentResult.Outputs.sandboxApiUrl.Value
Warmup-Website $odsDeploymentResult.Outputs.productionApiUrl.Value
Warmup-Website $odsDeploymentResult.Outputs.swaggerUrl.Value
Warmup-Website $adminAppDeploymentResult.Outputs.adminAppUrl.Value

Write-Success "Deployment Complete"

$resourceCostNotificationMessage = "All newly deployed resources will now incur costs until they are manually removed from the Azure portal."

Write-Success "*** NOTE ***"
Write-Success $resourceCostNotificationMessage
Write-Success "***"


[System.Windows.Forms.MessageBox]::Show($resourceCostNotificationMessage, "Deployment Complete") 