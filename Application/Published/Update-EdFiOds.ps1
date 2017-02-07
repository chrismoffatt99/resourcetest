<#
.SYNOPSIS
	Updates Ed-Fi ODS resources with a newer version published by Ed-Fi
.DESCRIPTION
	Updates Ed-Fi ODS resources with a newer version published by Ed-Fi
.PARAMETER Version
	Version number to update the given Ed-Fi ODS; if not provided, the latest available version will be used
.PARAMETER InstallFriendlyName
	Install-friendly name or Resource group name of the Ed-Fi ODS instance that will be scaled
.EXAMPLE
	.\Update-EdFiODS -InstallFriendlyName "EdFi ODS" 
#>
Param(
	[Version]
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
	$Force
)

$Edition = 'release'

$OdsTemplateFile = "$TemplateFileDirectory\OdsUpdate.json"
$OdsTemplateParametersFile = "$TemplateFileDirectory\OdsUpdate.parameters.json"

Import-Module $PSScriptRoot\EdFiOdsDeploy.psm1 -Force -DisableNameChecking

function Validate-RequestedInstallVersionExists()
{
	if (-not $Version)
	{
		$script:Version = Get-LatestCloudOdsVersion $Edition
	}

	else
	{
		Validate-VersionAndEdition $Version.ToString() $Edition
	}
}

function Validate-UpdateIsPossible()
{
	$currentVersion = Get-CloudOdsVersion $InstallFriendlyName
	if ($currentVersion -gt $Version -and -not $Force)
	{
		Write-Error "Ed-Fi ODS '$InstallFriendlyName' currently has version $currentVersion installed, but you are trying to install version $Version.  If you intend to downgrade your installed version, please pass the -Force flag to this script."
	}

	if ($currentVersion -eq $Version -and -not $Force)
	{
		Write-Error "Ed-Fi ODS '$InstallFriendlyName' is already at version $currentVersion.  If you intend to re-install, please pass the -Force flag to this script."
	}

	if ($Version.Major -gt $currentVersion.Major)
	{
		Write-Error "Ed-Fi ODS '$InstallFriendlyName' currently has version $currentVersion installed, but you are trying to install version $Version.  Major version upgrades are not currently supported."
	}
}

function Update-OdsVersion($resourceGroupName)
{
	$tags = @{"Cloud-Ods-Version" = $Version; "Cloud-Ods-Edition" = $Edition; "Cloud-Ods-FriendlyName" = $InstallFriendlyName}
	Set-AzureRmResourceGroup -Name $resourceGroupName -Tags $tags
}

function Update-Ods()
{
	Write-Host "Updating EdFi ODS to version $Version"
	$resourceGroupName = Get-ResourceGroupName $InstallFriendlyName
		
	$deployParameters = New-Object -TypeName Hashtable
	$deployParameters.Add("version", $Version.ToString())
	$deployParameters.Add("edition", $Edition)
	
	$templateFile = $OdsTemplateFile
	$templateParametersFile = $OdsTemplateParametersFile
		
    $deploymentResult = New-AzureRmResourceGroupDeployment -Name ((Get-ChildItem $templateFile).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
                                   -ResourceGroupName $resourceGroupName `
                                   -TemplateFile $templateFile `
                                   -TemplateParameterFile $templateParametersFile `
                                   @deployParameters `
                                   -Force -Verbose -ErrorAction Stop
	
	Update-OdsVersion $resourceGroupName

	return $deploymentResult
}

Verify-PowershellCmdletsInstalled
Validate-RequestedInstallVersionExists
Login-AzureAccount
Validate-UpdateIsPossible
$deploymentResult = Update-Ods

Warmup-Website $deploymentResult.Outputs.sandboxApiUrl.Value
Warmup-Website $deploymentResult.Outputs.productionApiUrl.Value
Warmup-Website $deploymentResult.Outputs.swaggerUrl.Value
Warmup-Website $deploymentResult.Outputs.adminAppUrl.Value

$adminAppUrl = $deploymentResult.Outputs.adminAppUrl.Value

Write-Success "Deployment Complete"
Write-Success "Login to the AdminApp ($adminAppUrl) to complete the Update process."