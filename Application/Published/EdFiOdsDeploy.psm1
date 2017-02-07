<#
	Cmdlets to help with deploying the Ed-Fi ODS
#>

$OdsAssetsStorageBaseUrl = "https://odsassets.blob.core.windows.net/public"
$OdsAssetsStorageAccountName = "odsassets";

function Assert-ResourceGroupExists([string]$resourceGroupName) {
	$retryTime = 5;
	$maxRetryTime = 60;
	Write-Host "Retrieving resource group $resourceGroupName"

	while($retryTime -lt $maxRetryTime) {
		$group = Get-AzureRmResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
		if ($group -ne $null) {
			return $true
		}
		Write-Host "Error locating $resourceGroupName, trying again in $retryTime seconds ... "
		Start-Sleep -Seconds $retryTime
		$retryTime = $retryTime * 2;
	}

	Write-Host "Error locating $resourceGroupName, trying again in $maxRetryTime seconds ... "
	Start-Sleep -Seconds $maxRetryTime
	$group = Get-AzureRmResourceGroup -Name $resourceGroupName -ErrorAction Stop
	 if ($group -eq $null) {
			return $false
	 }
	 return $true;
}

function Create-KeyVault([string]$resourceGroupName, [string]$resourceGroupLocation, [string]$resourceGroupUniqueId)
{
	$vaultName = 'OdsVault-' + $resourceGroupUniqueId
	$existingVault = Get-AzureRmKeyVault -VaultName $vaultName  -ErrorAction SilentlyContinue
	if ($existingVault -ne $null)
	{
		Write-Host "Vault $vaultName already exists."
		return $existingVault
	}

	$newVault = New-AzureRmKeyVault -VaultName $vaultName -ResourceGroupName $resourceGroupName -Location $resourceGroupLocation	
	
	#Short sleep to ensure key vault creation fully completes.  
	#Test runs have shown errors if the key vault is referenced
	#immediately after it is created
	Start-Sleep -Seconds 15
	
	return $newVault 
}

function Create-Password([int]$length = 16)
{
	$ascii = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_=+<>,./?\|";	
	return Get-RandomString $ascii $length
}

function Create-ResourceGroup([string]$friendlyName, [string]$resourceGroupLocation, [string]$version, [string]$edition)
{
	$resourceGroupName = Get-ResourceGroupName $friendlyName

	$group = Get-AzureRmResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
	if ($group -eq $null)
	{
		Write-Host "Creating new Resource Group: $resourceGroupName... "
		$tags = @{"Cloud-Ods-Version" = $version; "Cloud-Ods-Edition" = $edition; "Cloud-Ods-FriendlyName" = $friendlyName}
		New-AzureRmResourceGroup -Name $resourceGroupName -Location $resourceGroupLocation -Tag $tags -Verbose -Force -ErrorAction Stop | Out-Null
		Write-Success "Resource Group Created Successfully."
	}

	else
	{
		Write-Error "Ed-Fi ODS instance with name '$friendlyName' already exists.  If you wish to re-install, you must remove the old installation of the Ed-Fi ODS manually in the Azure portal by deleting the '$resourceGroupName' Resource Group."
	}

	return $resourceGroupName
}

function Delete-ResourceGroup([string]$resourceGroupName) {
	$retryTime = 5;
	$maxRetryTime = 60;

	$resourceGroupExists = Assert-ResourceGroupExists $resourceGroupName -ErrorAction Stop

	if ($resourceGroupExists -eq $false) {
		throw "Unable to locate resource group for deletion"
	}

	$success = $false
	while(($retryTime -lt $maxRetryTime) -and ($success -eq $false)) {
		Write-Host "Removing resource group: $resourceGroupName... "
		$success = Remove-AzureRmResourceGroup -Name $resourceGroupName -Force -ErrorAction SilentlyContinue
		if ($success -eq $false) {
			Write-Host "Error deleting $resourceGroupName, trying again in $retryTime seconds ... "
			Start-Sleep -Seconds $retryTime
			$retryTime *= 2;
		}
	}

	if ($success -eq $false) {
		Write-Host "Error deleting $resourceGroupName, trying again in $maxRetryTime seconds ... "
		Start-Sleep -Seconds $maxRetryTime
		Remove-AzureRmResourceGroup -Name $resourceGroupName -Force -ErrorAction Stop
	}

	Write-Host "Request to delete $resourceGroupName submitted successfully."
}

function Get-AzureSqlPasswordErrorMessage([PSCredential] $credentials)
{
	<#
	.DESCRIPTION

	Checks that the entered credentials meet Microsoft's SQL Server Strong Password Requirements
	See: https://support.microsoft.com/en-us/kb/965823

	If a password does not meet complexity requirements, an error message is returned indicating what exactly is missing
	#>

	$plaintextPassword = [string] (SecureString-ToPlainText $credentials.Password)
	$messages = @()

	if ($plaintextPassword.Length -lt 8) { $messages += "Your password must be at least 8 characters long" }
	if ($plaintextPassword.ToLower() -match $credentials.Username.ToLower()) { $messages += "Your password may not contain your username" }
	if ($plaintextPassword -match "`"")
	{
		$messages += "Your password may not contain double quotes (`")"
	}

	if ((Get-PasswordCharacterCategoryCount $credentials.Password) -lt 3)
	{
		$messages += "Your password must contain characters from at least three of the following categories:"
		$messages += "    -English uppercase characters (A through Z)"
		$messages += "    -English lowercase characters (a through z)"
		$messages += "    -Base 10 digits (0 through 9)"
		$messages += "    -All Nonalphabetic characters except double quotes (for example: !, $, #, % but not `")"
	}

	return $messages
}


function Get-CloudOdsResourceGroup($friendlyName)
{
	$resourceGroupName = Get-ResourceGroupName $friendlyName
	$group = Get-AzureRmResourceGroup -Name $resourceGroupName -ErrorAction Silently

	if ($group -eq $null)
	{
		Write-Error "Can't find existing Ed-Fi ODS named '$friendlyName' in your account"
	}

	return $group
}

function Get-CloudOdsVersion($friendlyName)
{
	$resourceGroup = Get-CloudOdsResourceGroup $friendlyName

	if ($resourceGroup.Tags -eq $null -or -not $resourceGroup.Tags.ContainsKey("Cloud-Ods-Version"))
	{
		Write-Error "Can't find current version for Ed-Fi ODS named '$friendlyName'"
	}

	$textVersion = $resourceGroup.Tags["Cloud-Ods-Version"]
	return [Version]$textVersion
}

function Get-CredentialAsPlainText([PSCredential] $credentials)
{
	return @{
		UserName = $credentials.UserName
		Password = (SecureString-ToPlainText $credentials.Password)
	}
}

function Get-CredentialFromConsole($prompt, $defaultUserName)
{
	if ($prompt) {
		Write-Host
		Write-Host $prompt
		Write-Host
	}	

	if ($defaultUserName) {
		$username = Read-Host -Prompt "Username [$defaultUserName]"
		if (!$username) {
			$username = $defaultUserName
		}
	} else {
		do {
			$username = Read-Host -Prompt "Username"
		} while (!$username)		
	}

	$passwordMatch = $false
	do {
		$password = Read-Host -Prompt "Password" -AsSecureString
		$confirmPassword = Read-Host -Prompt "Confirm Password" -AsSecureString

		if (SecureString-Equals $password $confirmPassword) {
			$passwordMatch = $true
		} else {			
			Write-Host "Passwords don't match"
		}
	} while (-not $passwordMatch)
	

	$credential = New-Object System.Management.Automation.PSCredential($username, $password)	
	return $credential
}

function Get-LatestCloudOdsVersion($edition)
{
	$latestVersionUrl = "$OdsAssetsStorageBaseUrl/$edition/LatestVersion.txt"
	try
	{
		$response = Invoke-WebRequest -Uri $latestVersionurl -UseBasicParsing
		$textVersion = $response.Content

		return [Version]$textVersion
	}	

	catch
	{
		Write-Error "Error retrieving version information for '$edition' edition - please check that this is a valid Cloud ODS edition"
	}	
}

function Get-PasswordCharacterCategoryCount([securestring] $securePassword)
{
	$plaintextPassword = (SecureString-ToPlainText $securePassword)
	$typesOfCharactersFound = 0

	#Contains at least one english lowercase character (a through z)
	if ($plaintextPassword -cmatch "[a-z]") { $typesOfCharactersFound++ }

	#Contains at least one english uppercase character (A through Z)
	if ($plaintextPassword -cmatch "[A-Z]") { $typesOfCharactersFound++ }

	#Contains at least one digit (0 through 9)
	if ($plaintextPassword -match "[0-9]") { $typesOfCharactersFound++ }

	#Contains at least one Nonalphabetic character
	if ($plaintextPassword -match "_|[^\w]") { $typesOfCharactersFound++ }

	return $typesOfCharactersFound
}

function Get-RandomId([int]$length = 13)
{
	$ascii = "abcdefghijklmnopqrstuvwxyz0123456789";	
	return Get-RandomString $ascii $length
}

function Get-RandomString([string] $alphabet, [int]$length)
{
	$charArray = $alphabet.ToCharArray();
	
	$result = ""
	for ($i = 1; $i –le $length; $i++) 
	{
		$result += ($charArray | Get-Random)
	}

	return $result
}

function Get-ResourceGroupName([string]$friendlyName)
{
	$friendlyName = $friendlyName -replace '\s', '_'	
	return $friendlyName.ToLowerInvariant()
}

function Get-ResourceGroupLocationsInTheUS()
{
	return (Get-AzureRmLocation | Where { $_.DisplayName -clike "*US*" }).DisplayName
}

function Get-NearestAppInsightsLocation([string]$selectedLocation)
{
	$supportedLocations = "East US", "South Central US"
    if ($supportedLocations -contains $selectedLocation) {
        return $selectedLocation
    } else {
        return "South Central US"
    }    
}

function Get-SqlUsernameErrorMessage([PSCredential] $credentials)
{
	$username = $credentials.UserName
	$messages = @()
	if ($username -match "[`"|:*?\\/#&;,%=]") { $messages += "Your username may not contain the following characters: `"|:*?\\/#&;,%=" }
	if ($username -match "\s") { $messages += "Your username may not contain spaces, tabs, or any other whitespace characters" }
	if ($username -match "^[0123456789@$+]") { $messages += "Your username may not begin with a digit (0-9), @, $, or +" }

	$invalidUsernamesFile = (Join-Path $PSScriptRoot 'invalid_usernames.txt')
	if (Test-Path $invalidUsernamesFile)
	{
		$usernameIsReserved = (Select-String $invalidUsernamesFile -pattern ("^" + $username.ToLower() + "$"))
		if ($usernameIsReserved)
		{
			$messages += "Your username may not be a reserved system name (eg: admin, administrator, root, dbo, public, etc)"
		}
	}

	return $messages
}

function Get-ValidatedCredentials($title, $messageBody, $usernameValidatorFunctionName, $passwordValidatorFunctionName)
{
	if ($usernameValidatorFunctionName -ne $null) {
		$validateUsername = (Get-Item -LiteralPath "function:$usernameValidatorFunctionName").ScriptBlock
	}
	if ($passwordValidatorFunctionName -ne $null) {
		$validatePassword = (Get-Item -LiteralPath "function:$passwordValidatorFunctionName").ScriptBlock
	}

	Do {	
		$credentials = Get-CredentialFromConsole $messageBody
		$errorMessages = @()
		
		if ($usernameValidatorFunctionName -ne $null) {
			$errorMessages += $validateUsername.Invoke($credentials)
		}
		if ($passwordValidatorFunctionName -ne $null) {
			$errorMessages += $validatePassword.Invoke($credentials)
		}
		$messageBody = [string]::Join(([environment]::NewLine), $errorMessages)
	} While ($errorMessages.Length -gt 0)

	return $credentials
}

function Login-AzureAccount()
{
	$loggedIn = $true;
	
	try
	{
		$context = Get-AzureRmContext -ErrorAction SilentlyContinue
		$subscription = Get-AzureRmSubscription -ErrorAction SilentlyContinue
		$loggedIn = (($context -ne $null) -and ($subscription -ne $null));
	}

	catch
	{
		$loggedIn = $false
	}	

	if (-not $loggedIn)
	{
		Login-AzureRmAccount -ErrorAction Stop
	}

	Select-Subscription		
}

function SecureString-ToPlainText([securestring] $value)
{
	$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($value)
	$PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

	return $PlainPassword
}

function SecureString-Equals([securestring] $value1, [securestring] $value2)
{
	return ((SecureString-ToPlainText $value1) -eq (SecureString-ToPlainText $value2))
}

function Select-ResourceGroupLocation()
{
	$locations = Get-ResourceGroupLocationsInTheUS
	$choice = -1

	if ($locations.length -gt 1)
	{
		while ($choice -eq -1)
		{
			Write-Host "Please choose which Azure datacenter to which you'd like to deploy.  You should try and use a region near you for optimal performance."

			$count = 1;
			foreach ($location in $locations)
			{
				Write-Host "[$count]: $location"
				$count++;
			}

			$input = Read-Host -Prompt "Resource Group Location"

			if ([int32]::TryParse($input, [ref]$choice))
			{
				if ($choice -gt 0 -and $choice -le $locations.length)
				{
					$selectedLocation = $locations[$choice-1]
					Write-Host "Using Resource Group Location ($selectedLocation)"
					return $selectedLocation
				}

				else
				{
					$choice = -1;
				}
			}

			else
			{
				$choice = -1;
			}
		}
	}
}

function Select-Subscription()
{
	$subscriptions = Get-AzureRmSubscription
	$choice = -1

	if ($subscriptions.length -gt 1)
	{
		while ($choice -eq -1)
		{
			Write-Host "Please choose which subscription to which you'd like to deploy:"

			$count = 1;
			foreach ($subscription in $subscriptions)
			{
				Write-Host "[$count]: $($subscription.SubscriptionName) - $($subscription.SubscriptionId)"
				$count++;
			}

			$input = Read-Host -Prompt "Subscription"

			if ([int32]::TryParse($input, [ref]$choice))
			{
				if ($choice -gt 0 -and $choice -le $subscriptions.length)
				{
					$choice -= 1;
				}

				else
				{
					$choice = -1;
				}
			}

			else
			{
				$choice = -1;
			}
		}	
	}

	Write-Host "Using Subscription $($subscriptions[$choice].SubscriptionName) - $($subscriptions[$choice].SubscriptionId)"
	Select-AzureRmSubscription -SubscriptionId $subscriptions[$choice].SubscriptionId
}

function Warmup-Website([string]$url)
{
	if (-not $url) { return; }
	Start-Job { Invoke-WebRequest $using:url } | Out-Null
}

function Validate-UserIsAzureGlobalAdmin()
{
	$loginId = (Get-AzureRMContext).Account.Id
	$adminUserRoles = Get-AzureRMRoleAssignment -RoleDefinitionName "ServiceAdministrator" -IncludeClassicAdministrators | where { $_.SignInName -eq $loginId -and $_.RoleDefinitionName.Contains("ServiceAdministrator") }

	if ($adminUserRoles -eq $null)
	{
		Write-Error "This account is not the Global Admin of the Azure Subscription specified.  This script must be run as the Global Admin."
	}
}

function Validate-VersionAndEdition([string] $versionNumber, [string] $edition)
{
	try
	{
		$context = New-AzureStorageContext -StorageAccountName $OdsAssetsStorageAccountName -Anonymous
		$blobs = Get-AzureStorageBlob -Context $context -Container "public" -Prefix "$edition/$versionNumber/"
	}

	catch
	{
	}
	
	if ($blobs -eq $null)
	{
		Write-Error "Could not find installation artifacts for Ed-Fi ODS $edition/$versionNumber -- please verify your version number is correct.";
	}	
}

function Verify-PowershellCmdletsInstalled()
{
	$version = (Get-Module -ListAvailable -Name Azure -Refresh).Version
	if ($version -eq $null)
	{
		Write-Error "You do not appear to have Azure Powershell Cmdlets installed.  See https://azure.microsoft.com/en-us/documentation/articles/powershell-install-configure/ for install instructions."
	}
}

function Write-Warning($message)
{
	Write-Host $message -ForegroundColor Yellow
}

function Write-Success($message = "Success")
{
	Write-Host $message -ForegroundColor Green
}

function Write-Error($message, $quitScript = $true)
{
	Write-Host "*** Error ***" -ForegroundColor Red
	Write-Host $message -ForegroundColor Red
	Write-Host "*************" -ForegroundColor Red

	if ($quitScript)
	{
		exit
	}
}

Export-ModuleMember -Function *