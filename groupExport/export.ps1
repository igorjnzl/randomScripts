param(
    [object] $WebhookData
)

# Extract parameters from webhook
Write-Output "Processing webhook request..."
$params = $WebhookData.RequestBody | ConvertFrom-Json
$User = $params.User
$StorageAccountName = $params.StorageAccountName
$ContainerName = $params.ContainerName
$BlobName = $params.BlobName ?? "groupMembership.csv"

Write-Output "Parameters - User: $User, Storage: $StorageAccountName, Container: $ContainerName"

if (-not $User -or -not $StorageAccountName -or -not $ContainerName) {
    Write-Error "Missing required parameters: User=$User, Storage=$StorageAccountName, Container=$ContainerName"
    throw "Missing required parameters"
}

# Authenticate and setup
Write-Output "Authenticating with managed identity..."
Connect-AzAccount -Identity
Write-Output "Getting Microsoft Graph access token..."
$token = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com/"
$headers = @{ 'Authorization' = "Bearer $($token.Token)" }
Write-Output "Authentication successful"
# Get user info
Write-Output "Looking up user: $User"
$userResponse = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$User" -Headers $headers
$userObj = @{ Id = $userResponse.id; DisplayName = $userResponse.displayName; UPN = $userResponse.userPrincipalName }
Write-Output "User found: $($userObj.DisplayName) ($($userObj.UPN))"

# Get group memberships
Write-Output "Retrieving transitive group memberships..."
$groups = @()
$uri = "https://graph.microsoft.com/v1.0/users/$($userObj.Id)/transitiveMemberOf"
$pageCount = 0
do {
    $pageCount++
    Write-Output "Processing membership page $pageCount..."
    $response = Invoke-RestMethod -Uri $uri -Headers $headers
    $pageGroups = $response.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' }
    Write-Output "Found $($pageGroups.Count) groups on page $pageCount"
    
    $groups += $pageGroups | ForEach-Object {
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$($_.id)?`$select=id,displayName,mail,mailEnabled,securityEnabled,visibility,groupTypes" -Headers $headers
    }
    $uri = $response.'@odata.nextLink'
} while ($uri)
Write-Output "Total groups found: $($groups.Count)"

$rows = $groups | ForEach-Object {
    [PSCustomObject]@{
        UserDisplayName   = $userObj.DisplayName
        UserPrincipalName = $userObj.UserPrincipalName
        UserObjectId      = $userObj.Id
        GroupDisplayName  = $_.displayName
        GroupId           = $_.id
        Mail              = $_.mail
        MailEnabled       = $_.mailEnabled
        SecurityEnabled   = $_.securityEnabled
        Visibility        = $_.visibility
        GroupTypes        = ($_.groupTypes -join ';')
        MembershipScope   = 'TransitiveMemberOf'
    }
}

# Generate CSV and upload
$blobName = $BlobName -replace '\.csv$', "_$($userObj.UPN -replace '[\\/:*?"<>|]', '_').csv"
$tempFile = [System.IO.Path]::GetTempFileName() + ".csv"
Write-Output "Generated blob name: $blobName"
Write-Output "Creating CSV with $($rows.Count) rows..."

try {
    $rows | Export-Csv -Path $tempFile -NoTypeInformation
    Write-Output "CSV file created: $tempFile"
    
    Write-Output "Connecting to storage account: $StorageAccountName"
    $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
    
    Write-Output "Uploading to container '$ContainerName' as blob '$blobName'..."
    $uploadResult = Set-AzStorageBlobContent -File $tempFile -Blob $blobName -Container $ContainerName -Context $ctx -Force -ErrorAction Stop
    
    if (-not $uploadResult) {
        throw "Blob upload failed"
    }
    
    $blobUrl = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$blobName"
    Write-Output "SUCCESS: Report uploaded to $blobUrl"
    
    return @{
        Status = "Success"
        Message = "Group membership report generated for $($userObj.DisplayName)"
        BlobUrl = $blobUrl
        User = $userObj.UPN
        GroupCount = $groups.Count
        Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss UTC')
    }
} catch {
    Write-Error "Upload failed: $($_.Exception.Message)"
    throw
} finally {
    Write-Output "Cleaning up temporary file..."
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
}
