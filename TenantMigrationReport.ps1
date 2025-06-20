# # Install the Az module if not already installed and import it
# Import-Module Az -ErrorAction Stop
# Import-Module Az.ResourceGraph -ErrorAction Stop

# Write-Host "Authenticating to Azure..." -ForegroundColor Cyan
# Connect-AzAccount | Out-Null

# # Get all subscriptions
# $subscriptions = Get-AzSubscription | Select-Object -ExpandProperty Id

# Replace with a valid existing resource group ID in your tenant for move API calls
$dummyTargetRG = "subscriptions/subsId/resourceGroups/rgId"

# Get Azure AD access token for REST API calls
function Get-AzAuthToken {
    return (Get-AzAccessToken).Token
}

# Check move support for a resource using REST API
function Get-MoveSupportStatus {
    param (
        [string]$resourceId,
        [string]$targetResourceGroup
    )
    $token = Get-AzAuthToken
    $uri = "https://management.azure.com$resourceId/moveResources?api-version=2021-04-01"
    $body = @{ targetResourceGroup = $targetResourceGroup } | ConvertTo-Json

    try {
        Invoke-RestMethod -Method POST -Uri $uri -Headers @{ Authorization = "Bearer $token" } -Body $body -ErrorAction Stop | Out-Null
        return @{ CanMove = $true; Details = "Move supported" }
    }
    catch {
        return @{ CanMove = $false; Details = $_.Exception.Message }
    }
}

# Detect resource locks
function Get-ResourceLocks {
    param ([string]$resourceId)
    try {
        $locks = Get-AzResourceLock -ResourceId $resourceId -ErrorAction Stop
        if ($locks) {
            return $true, ($locks | ForEach-Object { $_.LockLevel }) -join ', '
        }
        else {
            return $false, ''
        }
    }
    catch {
        return $false, ''
    }
}

# Find dependencies referencing this resource via Resource Graph
function Get-ResourceDependencies {
    param ([string]$resourceId)

    if ($resourceId -match '/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/(.+)') {
        $subscriptionId = $Matches[1]
        $resourceGroup = $Matches[2]
    }
    else {
        return @()
    }

    $query = @"
Resources
| where subscriptionId == '$subscriptionId' and resourceGroup == '$resourceGroup'
| where properties contains '$resourceId'
| project id, name, type
"@

    return Search-AzGraph -Query $query -Subscription $subscriptionId
}

# Get role assignments scoped to a given scope (subscription, resource group, or resource)
function Get-RoleAssignmentsByScope {
    param([string]$scope)

    try {
        return Get-AzRoleAssignment -Scope $scope -ErrorAction Stop
    }
    catch {
        
        return @()
    }
}

# Helper: Get principal display name from objectId
function Get-PrincipalDisplayName {
    param([string]$objectId)

    try {
        $principal = Get-AzADUser -ObjectId $objectId -ErrorAction SilentlyContinue
        if ($principal) { return $principal.DisplayName }

        $principal = Get-AzADGroup -ObjectId $objectId -ErrorAction SilentlyContinue
        if ($principal) { return $principal.DisplayName }

        $principal = Get-AzADServicePrincipal -ObjectId $objectId -ErrorAction SilentlyContinue
        if ($principal) { return $principal.DisplayName }

        return $objectId
    }
    catch {
        return $objectId
    }
}

# Generic official migration guidance links
$genericMigrationLinks = @(
    "Azure Migrate: https://learn.microsoft.com/en-us/azure/azure-migrate/",
    "Azure Resource Mover (region moves): https://learn.microsoft.com/en-us/azure/resource-mover/",
    "Move support docs: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/move-support-resources"
) -join '; '

Write-Host "Querying all resources across subscriptions..." -ForegroundColor Cyan
$resources = Search-AzGraph -Query "Resources | project id, name, type, location, subscriptionId, resourceGroup" -Subscription $subscriptions

$output = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Host "Gathering role assignments at subscription and resource group levels..." -ForegroundColor Cyan

# Cache role assignments per subscription and resource group to avoid repeated calls
$roleAssignmentsCache = @{}

foreach ($subId in $subscriptions) {
    # Set Azure context to current subscription
    Set-AzContext -Subscription $subId | Out-Null

    # Subscription level role assignments
    $roleAssignmentsCache["sub:$subId"] = Get-RoleAssignmentsByScope -scope "/subscriptions/$subId"

    # Get resource groups in current subscription context
    $rgs = Get-AzResourceGroup
    foreach ($rg in $rgs) {
        $scopeRG = "/subscriptions/$subId/resourceGroups/$($rg.ResourceGroupName)"
        $roleAssignmentsCache["rg:$scopeRG"] = Get-RoleAssignmentsByScope -scope $scopeRG
    }
}


Write-Host "Processing resources and gathering all data..." -ForegroundColor Cyan

foreach ($res in $resources) {
    Write-Host "Processing resource: $($res.Name) [$($res.Type)]" -ForegroundColor DarkGray

    # Move support
    $moveStatus = Get-MoveSupportStatus -resourceId $res.id -targetResourceGroup $dummyTargetRG

    # Locks
    $hasLock, $lockLevels = Get-ResourceLocks -resourceId $res.id
    $knownLimitations = if ($hasLock) { "Resource has locks: $lockLevels. Remove locks before move." } else { "" }

    # Dependencies
    $dependencies = Get-ResourceDependencies -resourceId $res.id
    $dependencyList = if ($dependencies.Count -gt 0) { $dependencies | ForEach-Object { $_.id } } else { @() }

    # Role assignments scoped to resource
    $roleAssignmentsResource = Get-RoleAssignmentsByScope -scope $res.id

    # Role assignments scoped to resource group
    $scopeRG = "/subscriptions/$($res.SubscriptionId)/resourceGroups/$($res.ResourceGroup)"
    $roleAssignmentsRG = $roleAssignmentsCache["rg:$scopeRG"]

    # Role assignments scoped to subscription
    $roleAssignmentsSub = $roleAssignmentsCache["sub:$($res.SubscriptionId)"]

    # Combine and deduplicate role assignments by principal and role definition
    $allRoleAssignments = @($roleAssignmentsResource) + @($roleAssignmentsRG) + @($roleAssignmentsSub)
    $uniqueRoleAssignments = $allRoleAssignments | Sort-Object ObjectId, RoleDefinitionName, Scope -Unique

    # Format role assignments for output
    $formattedRoles = $uniqueRoleAssignments | ForEach-Object {
        $displayName = Get-PrincipalDisplayName -objectId $_.ObjectId
        [PSCustomObject]@{
            PrincipalName = $displayName
            RoleName = $_.RoleDefinitionName
            Scope = $_.Scope
        }
    }

    $output.Add([PSCustomObject]@{
        ResourceId          = $res.id
        ResourceName        = $res.name
        ResourceType        = $res.type
        Location            = $res.location
        SubscriptionId      = $res.subscriptionId
        ResourceGroup       = $res.resourceGroup
        MoveSupported       = if ($moveStatus.CanMove) { "Yes" } else { "No" }
        Recommendation      = if ($moveStatus.CanMove) { "Move supported." } else { "Move NOT supported; consider manual migration." }
        KnownLimitations    = $knownLimitations
        Dependencies        = ($dependencyList -join '; ')
        DocumentationLinks  = $genericMigrationLinks
        MoveSupportDetails  = $moveStatus.Details
        RoleAssignments     = $formattedRoles
    })
}

# Group by ResourceType and SubscriptionId for summary
$groupedSummary = $output |
    Group-Object -Property ResourceType, SubscriptionId |
    ForEach-Object {
        [PSCustomObject]@{
            ResourceType    = $_.Name.Split(',')[0].Trim()
            SubscriptionId  = $_.Name.Split(',')[1].Trim()
            ResourceCount   = $_.Count
            Resources       = $_.Group | Select-Object ResourceName, ResourceGroup, MoveSupported
        }
    }

# Export reports
$reportFolder = Join-Path -Path $PWD -ChildPath "TenantMigrationReports"
if (-not (Test-Path $reportFolder)) { New-Item -Path $reportFolder -ItemType Directory | Out-Null }

$reportCsv = Join-Path $reportFolder 'TenantMigrationReport_Details.csv'
$reportJson = Join-Path $reportFolder 'TenantMigrationReport_Details.json'
$summaryJson = Join-Path $reportFolder 'TenantMigrationReport_Summary.json'

# Export detailed CSV with simplified role assignments (principal names and roles concatenated)
$output | Select-Object ResourceId, ResourceName, ResourceType, Location, SubscriptionId, ResourceGroup,
    MoveSupported, Recommendation, KnownLimitations, Dependencies, DocumentationLinks, MoveSupportDetails,
    @{Name='RoleAssignmentsSummary'; Expression={
        if ($_.RoleAssignments) {
            ($_.RoleAssignments | ForEach-Object { "$($_.PrincipalName): $($_.RoleName) [$($_.Scope)]" }) -join '; '
        } else {
            ''
        }
    }} | Export-Csv -Path $reportCsv -NoTypeInformation -Encoding UTF8





# Export full JSON with role assignments objects
$output | ConvertTo-Json -Depth 10 | Out-File -FilePath $reportJson -Encoding utf8
$groupedSummary | ConvertTo-Json -Depth 5 | Out-File -FilePath $summaryJson -Encoding utf8

Write-Host "`n✅ Reports generated in folder: $reportFolder"
Write-Host "  • Detailed CSV: $reportCsv"
Write-Host "  • Detailed JSON: $reportJson"
Write-Host "  • Grouped Summary JSON: $summaryJson"
