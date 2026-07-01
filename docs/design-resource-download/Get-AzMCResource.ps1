#Requires -Version 7.0
<#
.SYNOPSIS
    Downloads and extracts a DSCv3 resource package for Azure Machine Configuration.

.DESCRIPTION
    Implements the package download flow:
      1. Coded against an API version (the ".well-known" discovery document version keys).
      2. Configured with one or more hostnames and a packages directory.
      3. Discovers API endpoints via service discovery
         (%hostname%/.well-known/azuremachineconfiguration.json).
      4. Takes a resource type and version.
      5. Discovers the package for the resource type
         (%MODULE_API_ENDPOINT%/%resource%/%version%/index.json).
      6. Discovers the archive for the package
         (%PACKAGE_API_ENDPOINT%/%package%/%package_version%.json).
      7. Selects the archive URL by platform (os_arch).
      8. Downloads the archive and verifies the hash.
      9. Extracts the package into %PACKAGES_DIR%\%package%\%package_version%.
     10. Adds the package version directory to the DSC_RESOURCE_PATH environment variable
         for the current process.
     11. Registers the resource type and version in %PACKAGES_DIR%\resources.json so
         later update checks can re-resolve the resource.

    The script can also update all registered resources and clean up cached package
    versions that are no longer required. These modes are intended to be called by a
    scheduled task or background agent.

.PARAMETER Resource
    The resource type, e.g. "Microsoft.GuestConfiguration/users".

.PARAMETER Version
    The resource type version, e.g. "2026-06-30-preview".

.PARAMETER Hostname
    One or more service hostnames to use for discovery. The first hostname that
    successfully serves the discovery document is used.

.PARAMETER PackagesDirectory
    The directory packages are extracted into. Defaults to "<script dir>\packages".

.PARAMETER PackageVersion
    Optional. The specific package version to download. When omitted, the highest
    version advertised by the module index is selected.

.PARAMETER Platform
    Optional. The os_arch platform key, e.g. "windows_amd64", "linux_amd64",
    "linux_arm64". Defaults to the current platform.

.PARAMETER UpdateRegisteredResources
    Re-resolves every resource in resources.json, downloads any newer selected package
    versions that are not already cached, and regenerates DSC_RESOURCE_PATH for this
    process.

.PARAMETER CleanupUnusedPackages
    Removes cached package version directories that are no longer required by any
    registered resource. When used with UpdateRegisteredResources, cleanup runs after
    updates complete.

.EXAMPLE
    .\Get-AzMCResource.ps1 -Resource "Microsoft.GuestConfiguration/users" -Version "2026-06-30-preview"

.EXAMPLE
    .\Get-AzMCResource.ps1 `
        -Resource "Microsoft.GuestConfiguration/users" `
        -Version "2026-06-30-preview" `
        -Hostname "agentserviceapi.guestconfiguration.azure.com" `
        -Platform "linux_amd64"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [string] $Resource,

    [Parameter()]
    [string] $Version,

    [Parameter()]
    [string[]] $Hostname = @('agentserviceapi.guestconfiguration.azure.com'),

    [Parameter()]
    [string] $PackagesDirectory = (Join-Path $PSScriptRoot 'packages'),

    [Parameter()]
    [string] $PackageVersion,

    [Parameter()]
    [string] $Platform,

    [Parameter()]
    [switch] $UpdateRegisteredResources,

    [Parameter()]
    [switch] $CleanupUnusedPackages
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Helpers ---------------------------------------------------------------

function Get-CurrentPlatform {
    if ($IsWindows) {
        $os = 'windows'
    }
    elseif ($IsLinux) {
        $os = 'linux'
    }
    elseif ($IsMacOS) {
        $os = 'darwin'
    }
    else {
        throw "Unable to determine the current operating system."
    }

    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64'   { 'amd64' }
        'Arm64' { 'arm64' }
        'X86'   { '386' }
        default { throw "Unsupported processor architecture: $_" }
    }

    return "${os}_${arch}"
}

function Get-JsonFromUri {
    param([Parameter(Mandatory)][string] $Uri)

    Write-Verbose "GET $Uri"
    return Invoke-RestMethod -Uri $Uri -Method Get -Headers @{ Accept = 'application/json' }
}

function Resolve-AbsoluteUri {
    param(
        [Parameter(Mandatory)][string] $BaseUri,
        [Parameter(Mandatory)][string] $Reference
    )

    if ([System.Uri]::IsWellFormedUriString($Reference, [System.UriKind]::Absolute)) {
        return $Reference
    }

    return [System.Uri]::new([System.Uri]::new($BaseUri), $Reference).AbsoluteUri
}

function Select-HighestVersion {
    param([Parameter(Mandatory)][string[]] $Versions)

    return $Versions | Sort-Object -Property {
        $parsed = $null
        if ([System.Version]::TryParse(($_ -split '-', 2)[0], [ref] $parsed)) {
            $parsed
        }
        else {
            [System.Version]::new(0, 0)
        }
    }, { $_ } | Select-Object -Last 1
}

function Get-ResourceRegistryPath {
    param([Parameter(Mandatory)][string] $PackagesDirectory)

    return Join-Path $PackagesDirectory 'resources.json'
}

function Read-LocalResourceRegistry {
    param([Parameter(Mandatory)][string] $PackagesDirectory)

    $registryPath = Get-ResourceRegistryPath -PackagesDirectory $PackagesDirectory
    if (-not (Test-Path -LiteralPath $registryPath)) {
        return [pscustomobject]@{ resources = @() }
    }

    $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
    if (-not $registry.PSObject.Properties['resources']) {
        throw "Resource registry '$registryPath' does not contain a 'resources' array."
    }

    return $registry
}

function Write-LocalResourceRegistry {
    param(
        [Parameter(Mandatory)][string] $PackagesDirectory,
        [Parameter(Mandatory)][object[]] $Resources
    )

    New-Item -ItemType Directory -Path $PackagesDirectory -Force | Out-Null

    $normalizedResources = @(
        $Resources |
            Where-Object { $_.resource -and $_.version } |
            ForEach-Object {
                [pscustomobject]@{
                    resource = $_.resource.Trim('/').ToLowerInvariant()
                    version  = $_.version.ToLowerInvariant()
                }
            } |
            Sort-Object -Property resource, version -Unique
    )

    $registry = [pscustomobject]@{ resources = $normalizedResources }
    $registryPath = Get-ResourceRegistryPath -PackagesDirectory $PackagesDirectory
    $registry | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $registryPath -Encoding utf8NoBOM
}

function Register-LocalResource {
    param(
        [Parameter(Mandatory)][string] $PackagesDirectory,
        [Parameter(Mandatory)][string] $Resource,
        [Parameter(Mandatory)][string] $Version
    )

    $registry = Read-LocalResourceRegistry -PackagesDirectory $PackagesDirectory
    $resources = @($registry.resources)
    $resources += [pscustomobject]@{
        resource = $Resource.Trim('/').ToLowerInvariant()
        version  = $Version.ToLowerInvariant()
    }

    Write-LocalResourceRegistry -PackagesDirectory $PackagesDirectory -Resources $resources
}

function Get-PackageVersionDirectory {
    param(
        [Parameter(Mandatory)][string] $PackagesDirectory,
        [Parameter(Mandatory)][string] $PackageName,
        [Parameter(Mandatory)][string] $PackageVersion
    )

    return Join-Path (Join-Path $PackagesDirectory $PackageName) $PackageVersion
}

function Resolve-ResourcePackage {
    param(
        [Parameter(Mandatory)][string] $Resource,
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][string] $ModuleEndpoint,
        [Parameter(Mandatory)][string] $PackagesDirectory,
        [Parameter()][string] $PackageVersion
    )

    $resourcePath = $Resource.Trim('/').ToLowerInvariant()
    $resourceVersion = $Version.ToLowerInvariant()
    $moduleIndexUri = "$($ModuleEndpoint.TrimEnd('/'))/$resourcePath/$resourceVersion.json"
    $moduleIndex = Get-JsonFromUri -Uri $moduleIndexUri

    if (-not $moduleIndex.PSObject.Properties['packages']) {
        throw "Module index '$moduleIndexUri' does not contain a 'packages' object."
    }

    $packageProperties = @($moduleIndex.packages.PSObject.Properties)
    if ($packageProperties.Count -eq 0) {
        throw "No packages found for resource '$Resource' version '$Version'."
    }

    # This flow assumes a single package per resource type.
    $packageName = $packageProperties[0].Name
    $packageVersionProperties = @($packageProperties[0].Value.versions.PSObject.Properties)
    if ($packageVersionProperties.Count -eq 0) {
        throw "Package '$packageName' has no published versions."
    }

    $availableVersions = @($packageVersionProperties.Name)
    if (-not $PackageVersion) {
        $PackageVersion = Select-HighestVersion -Versions $availableVersions
    }
    elseif ($PackageVersion -notin $availableVersions) {
        throw "Package version '$PackageVersion' is not available. Available: $($availableVersions -join ', ')."
    }

    $destination = Get-PackageVersionDirectory `
        -PackagesDirectory $PackagesDirectory `
        -PackageName $packageName `
        -PackageVersion $PackageVersion

    return [pscustomobject]@{
        Resource       = $resourcePath
        Version        = $resourceVersion
        Package        = $packageName
        PackageVersion = $PackageVersion
        ModuleIndexUri = $moduleIndexUri
        Path           = $destination
    }
}

function Install-PackageVersion {
    param(
        [Parameter(Mandatory)][string] $PackageName,
        [Parameter(Mandatory)][string] $PackageVersion,
        [Parameter(Mandatory)][string] $PackageEndpoint,
        [Parameter(Mandatory)][string] $Platform,
        [Parameter(Mandatory)][string] $PackagesDirectory,
        [Parameter()][switch] $Force
    )

    $destination = Get-PackageVersionDirectory `
        -PackagesDirectory $PackagesDirectory `
        -PackageName $PackageName `
        -PackageVersion $PackageVersion

    if ((Test-Path -LiteralPath $destination -PathType Container) -and -not $Force.IsPresent) {
        Write-Verbose "Package '$PackageName' $PackageVersion is already present at '$destination'."
        return [pscustomobject]@{
            Package        = $PackageName
            PackageVersion = $PackageVersion
            Platform       = $Platform
            Path           = $destination
            Downloaded     = $false
        }
    }

    $packageInfoUri = "$($PackageEndpoint.TrimEnd('/'))/$($PackageName.ToLowerInvariant())/$($PackageVersion.ToLowerInvariant()).json"
    $packageInfo = Get-JsonFromUri -Uri $packageInfoUri

    if (-not $packageInfo.PSObject.Properties['archives']) {
        throw "Package document '$packageInfoUri' does not contain an 'archives' object."
    }

    $archive = $packageInfo.archives.PSObject.Properties[$Platform]
    if (-not $archive) {
        $supported = $packageInfo.archives.PSObject.Properties.Name -join ', '
        throw "Package '$PackageName' $PackageVersion has no archive for platform '$Platform'. Available: $supported."
    }

    $archive = $archive.Value
    $archiveUri = Resolve-AbsoluteUri -BaseUri $packageInfoUri -Reference $archive.url
    $tempArchive = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + '.zip')

    try {
        Write-Verbose "Downloading $archiveUri -> $tempArchive"
        Invoke-WebRequest -Uri $archiveUri -OutFile $tempArchive

        $hashEntries = @($archive.hashes)
        if ($hashEntries.Count -eq 0) {
            throw "Archive for '$PackageName' $PackageVersion ($Platform) has no hashes to verify."
        }

        $verified = $false
        foreach ($entry in $hashEntries) {
            $parts = $entry -split ':', 2
            if ($parts.Count -ne 2) {
                Write-Warning "Skipping malformed hash entry '$entry'."
                continue
            }

            $algorithm = $parts[0].ToUpperInvariant()
            $expected = $parts[1].Trim()
            $actual = (Get-FileHash -Path $tempArchive -Algorithm $algorithm).Hash

            if ($actual -ieq $expected) {
                $verified = $true
                Write-Verbose "$algorithm hash verified."
                break
            }

            throw "$algorithm hash mismatch. Expected '$expected', got '$actual'."
        }

        if (-not $verified) {
            throw "Unable to verify the archive hash for '$PackageName' $PackageVersion ($Platform)."
        }

        if (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Recurse -Force
        }
        New-Item -ItemType Directory -Path $destination -Force | Out-Null

        Write-Verbose "Extracting to $destination"
        Expand-Archive -LiteralPath $tempArchive -DestinationPath $destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempArchive) {
            Remove-Item -LiteralPath $tempArchive -Force
        }
    }

    return [pscustomobject]@{
        Package        = $PackageName
        PackageVersion = $PackageVersion
        Platform       = $Platform
        Path           = $destination
        Downloaded     = $true
    }
}

function Get-NormalizedFullPath {
    param([Parameter(Mandatory)][string] $Path)

    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Test-PathUnderDirectory {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Directory
    )

    $fullPath = Get-NormalizedFullPath -Path $Path
    $fullDirectory = Get-NormalizedFullPath -Path $Directory
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

    return $fullPath.Equals($fullDirectory, $comparison) -or
        $fullPath.StartsWith("$fullDirectory$([System.IO.Path]::DirectorySeparatorChar)", $comparison)
}

function Add-DscResourcePath {
    param([Parameter(Mandatory)][string] $Path)

    $separator = [System.IO.Path]::PathSeparator
    $existingPaths = @()
    if (-not [string]::IsNullOrEmpty($env:DSC_RESOURCE_PATH)) {
        $existingPaths = @($env:DSC_RESOURCE_PATH -split [regex]::Escape($separator) | Where-Object { $_ })
    }

    $env:DSC_RESOURCE_PATH = @($existingPaths + $Path | Select-Object -Unique) -join $separator
}

function Set-DscResourcePathFromPackages {
    param(
        [Parameter(Mandatory)][string] $PackagesDirectory,
        [Parameter(Mandatory)][string[]] $PackagePath
    )

    $separator = [System.IO.Path]::PathSeparator
    $existingPaths = @()
    if (-not [string]::IsNullOrEmpty($env:DSC_RESOURCE_PATH)) {
        $existingPaths = @($env:DSC_RESOURCE_PATH -split [regex]::Escape($separator) | Where-Object { $_ })
    }

    $nonPackagePaths = @(
        $existingPaths | Where-Object { -not (Test-PathUnderDirectory -Path $_ -Directory $PackagesDirectory) }
    )
    $desiredPackagePaths = @($PackagePath | ForEach-Object { Get-NormalizedFullPath -Path $_ } | Select-Object -Unique)

    $env:DSC_RESOURCE_PATH = @($nonPackagePaths + $desiredPackagePaths | Select-Object -Unique) -join $separator
}

function Resolve-RegisteredResourcePackage {
    param(
        [Parameter(Mandatory)][string] $PackagesDirectory,
        [Parameter(Mandatory)][string] $ModuleEndpoint
    )

    $registry = Read-LocalResourceRegistry -PackagesDirectory $PackagesDirectory
    $registeredResources = @($registry.resources)
    foreach ($registeredResource in $registeredResources) {
        if (-not $registeredResource.PSObject.Properties['resource'] -or -not $registeredResource.PSObject.Properties['version']) {
            throw "Every resource registry entry must contain 'resource' and 'version'."
        }

        Resolve-ResourcePackage `
            -Resource $registeredResource.resource `
            -Version $registeredResource.version `
            -ModuleEndpoint $ModuleEndpoint `
            -PackagesDirectory $PackagesDirectory
    }
}

function Get-CachedPackageVersionDirectory {
    param([Parameter(Mandatory)][string] $PackagesDirectory)

    if (-not (Test-Path -LiteralPath $PackagesDirectory -PathType Container)) {
        return
    }

    foreach ($namespaceDirectory in Get-ChildItem -LiteralPath $PackagesDirectory -Directory) {
        foreach ($packageDirectory in Get-ChildItem -LiteralPath $namespaceDirectory.FullName -Directory) {
            foreach ($versionDirectory in Get-ChildItem -LiteralPath $packageDirectory.FullName -Directory) {
                [pscustomobject]@{
                    Package        = "$($namespaceDirectory.Name)/$($packageDirectory.Name)"
                    PackageVersion = $versionDirectory.Name
                    Path           = $versionDirectory.FullName
                }
            }
        }
    }
}

function Remove-UnusedPackageVersionDirectory {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string] $PackagesDirectory,
        [Parameter(Mandatory)][string[]] $RequiredPath
    )

    $pathComparer = if ($IsWindows) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
    $requiredPaths = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
    foreach ($path in $RequiredPath) {
        $requiredPaths.Add((Get-NormalizedFullPath -Path $path)) | Out-Null
    }

    $activePaths = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
    if (-not [string]::IsNullOrEmpty($env:DSC_RESOURCE_PATH)) {
        foreach ($path in ($env:DSC_RESOURCE_PATH -split [regex]::Escape([System.IO.Path]::PathSeparator))) {
            if ($path) {
                $activePaths.Add((Get-NormalizedFullPath -Path $path)) | Out-Null
            }
        }
    }

    foreach ($cachedPackage in Get-CachedPackageVersionDirectory -PackagesDirectory $PackagesDirectory) {
        $cachedPath = Get-NormalizedFullPath -Path $cachedPackage.Path
        if ($requiredPaths.Contains($cachedPath)) {
            continue
        }

        if ($activePaths.Contains($cachedPath)) {
            Write-Warning "Skipping active package path '$cachedPath'."
            continue
        }

        if ($PSCmdlet.ShouldProcess($cachedPath, 'Remove unused cached package version')) {
            Remove-Item -LiteralPath $cachedPath -Recurse -Force
            [pscustomobject]@{
                Package        = $cachedPackage.Package
                PackageVersion = $cachedPackage.PackageVersion
                Path           = $cachedPath
                Removed        = $true
            }
        }
    }
}

# --- 3. Service discovery --------------------------------------------------

function Get-DiscoveryDocument {
    param([Parameter(Mandatory)][string[]] $Hostnames)

    foreach ($serviceHost in $Hostnames) {
        # Accept a bare hostname (defaults to https) or a full base URL
        # that already includes a scheme and optional port.
        if ($serviceHost -match '^[A-Za-z][A-Za-z0-9+.-]*://') {
            $base = $serviceHost.TrimEnd('/')
        }
        else {
            $base = "https://$($serviceHost.TrimEnd('/'))"
        }
        $uri = "$base/.well-known/azuremachineconfiguration.json"
        try {
            return Get-JsonFromUri -Uri $uri
        }
        catch {
            Write-Warning "Discovery failed for '$serviceHost': $($_.Exception.Message)"
        }
    }

    throw "Service discovery failed for all hostnames: $($Hostnames -join ', ')"
}

# --- Main flow -------------------------------------------------------------

if (-not $Platform) {
    $Platform = Get-CurrentPlatform
}
Write-Verbose "Target platform: $Platform"

$isInstallMode = -not $UpdateRegisteredResources.IsPresent -and -not $CleanupUnusedPackages.IsPresent
if ($isInstallMode -and ([string]::IsNullOrWhiteSpace($Resource) -or [string]::IsNullOrWhiteSpace($Version))) {
    throw "Resource and Version are required unless UpdateRegisteredResources or CleanupUnusedPackages is specified."
}

if ((-not $isInstallMode) -and $PackageVersion) {
    throw "PackageVersion is only supported when installing a single resource."
}

# 3. Discover API endpoints.
$discovery = Get-DiscoveryDocument -Hostnames $Hostname
$moduleEndpoint = $discovery.'modules.v1'
$packageEndpoint = $discovery.'packages.v1'

if (-not $moduleEndpoint) { throw "Discovery document is missing 'modules.v1'." }
if (-not $packageEndpoint) { throw "Discovery document is missing 'packages.v1'." }

Write-Verbose "modules.v1  = $moduleEndpoint"
Write-Verbose "packages.v1 = $packageEndpoint"

if ($isInstallMode) {
    $resolvedPackage = Resolve-ResourcePackage `
        -Resource $Resource `
        -Version $Version `
        -ModuleEndpoint $moduleEndpoint `
        -PackagesDirectory $PackagesDirectory `
        -PackageVersion $PackageVersion

    Write-Verbose "Selected package '$($resolvedPackage.Package)' version '$($resolvedPackage.PackageVersion)'."

    $installation = Install-PackageVersion `
        -PackageName $resolvedPackage.Package `
        -PackageVersion $resolvedPackage.PackageVersion `
        -PackageEndpoint $packageEndpoint `
        -Platform $Platform `
        -PackagesDirectory $PackagesDirectory `
        -Force

    Register-LocalResource `
        -PackagesDirectory $PackagesDirectory `
        -Resource $Resource `
        -Version $Version

    Add-DscResourcePath -Path $installation.Path

    Write-Host "Resource '$Resource' ($Version) installed:"
    Write-Host "  Package         : $($resolvedPackage.Package)"
    Write-Host "  Version         : $($resolvedPackage.PackageVersion)"
    Write-Host "  Platform        : $Platform"
    Write-Host "  Path            : $($installation.Path)"
    Write-Host "  Registry        : $(Get-ResourceRegistryPath -PackagesDirectory $PackagesDirectory)"
    Write-Host "  DSC_RESOURCE_PATH = $env:DSC_RESOURCE_PATH"

    [pscustomobject]@{
        Operation       = 'Install'
        Resource        = $Resource
        Version         = $Version
        Package         = $resolvedPackage.Package
        PackageVersion  = $resolvedPackage.PackageVersion
        Platform        = $Platform
        Path            = $installation.Path
        Downloaded      = $installation.Downloaded
        Registered      = $true
        DscResourcePath = $env:DSC_RESOURCE_PATH
    }

    return
}

$resolvedPackages = @(Resolve-RegisteredResourcePackage `
    -PackagesDirectory $PackagesDirectory `
    -ModuleEndpoint $moduleEndpoint)

if ($resolvedPackages.Count -eq 0) {
    Write-Warning "No registered resources found in '$(Get-ResourceRegistryPath -PackagesDirectory $PackagesDirectory)'."
    return
}

if ($UpdateRegisteredResources.IsPresent) {
    $updateResults = @()
    foreach ($resolvedPackage in $resolvedPackages) {
        Write-Verbose "Resolved '$($resolvedPackage.Resource)' $($resolvedPackage.Version) to '$($resolvedPackage.Package)' $($resolvedPackage.PackageVersion)."

        $installation = Install-PackageVersion `
            -PackageName $resolvedPackage.Package `
            -PackageVersion $resolvedPackage.PackageVersion `
            -PackageEndpoint $packageEndpoint `
            -Platform $Platform `
            -PackagesDirectory $PackagesDirectory

        $updateResults += [pscustomobject]@{
            Operation       = 'Update'
            Resource        = $resolvedPackage.Resource
            Version         = $resolvedPackage.Version
            Package         = $resolvedPackage.Package
            PackageVersion  = $resolvedPackage.PackageVersion
            Platform        = $Platform
            Path            = $installation.Path
            Downloaded      = $installation.Downloaded
            DscResourcePath = $null
        }
    }

    Set-DscResourcePathFromPackages `
        -PackagesDirectory $PackagesDirectory `
        -PackagePath @($resolvedPackages.Path)

    foreach ($updateResult in $updateResults) {
        $updateResult.DscResourcePath = $env:DSC_RESOURCE_PATH
        $updateResult
    }

    Write-Verbose "DSC_RESOURCE_PATH = $env:DSC_RESOURCE_PATH"
}

if ($CleanupUnusedPackages.IsPresent) {
    $missingRequiredPackagePaths = @($resolvedPackages.Path | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) })
    if ($missingRequiredPackagePaths.Count -gt 0) {
        throw "Cannot clean up package cache because required package paths are missing: $($missingRequiredPackagePaths -join ', '). Run with -UpdateRegisteredResources first."
    }

    Remove-UnusedPackageVersionDirectory `
        -PackagesDirectory $PackagesDirectory `
        -RequiredPath @($resolvedPackages.Path)
}
