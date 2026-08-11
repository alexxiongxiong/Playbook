<#
.SYNOPSIS
Finds the AKS Istio Gateway, HTTPRoute, EnvoyFilter, and xDS resources for a request.

.DESCRIPTION
Native PowerShell translation of find-aks-istio-request-resources.sh.
Parameters take precedence over the original environment variables:
HOST, LB_IP, SCHEME, PORT, REQ_METHOD, REQ_PATH, GW_NS, GW,
ISTIO_ROOT_NS, ISTIO_CONTROL_PLANE_NS, ISTIO_REVISION, and DUMP_XDS.

.PARAMETER HostName
Request host name. Maps to HOST. Required.

.PARAMETER LoadBalancerIp
Gateway address used for automatic Gateway discovery. Maps to LB_IP.
Required unless GatewayNamespace and GatewayName are both supplied.

.PARAMETER Scheme
Request scheme. Maps to SCHEME. Supported values: http, https. Default: https.

.PARAMETER Port
Request port. Maps to PORT. Default: 443.

.PARAMETER RequestMethod
Request method. Maps to REQ_METHOD. Default: GET.

.PARAMETER RequestPath
Request path. Maps to REQ_PATH. Default: /.

.PARAMETER GatewayNamespace
Explicit Gateway namespace. Maps to GW_NS.

.PARAMETER GatewayName
Explicit Gateway name. Maps to GW.

.PARAMETER IstioRootNamespace
Istio root namespace for mesh-wide EnvoyFilters. Maps to ISTIO_ROOT_NS.
Default: aks-istio-system.

.PARAMETER IstioControlPlaneNamespace
Istio control plane namespace used by istioctl proxy-status. Maps to
ISTIO_CONTROL_PLANE_NS. Default: aks-istio-system.

.PARAMETER IstioRevision
Istio revision. Maps to ISTIO_REVISION. If omitted, the script reads
istio.io/rev from the Gateway Pod when available.

.PARAMETER DumpXds
Runs istioctl proxy-status, proxy-config listener, and proxy-config route
after static matching. Maps to DUMP_XDS.

.EXAMPLE
.\find-aks-istio-request-resources.ps1 `
  -HostName 'aiahk-dslab-dev.aiaazure.biz' `
  -LoadBalancerIp '10.240.0.6' `
  -RequestPath '/api/v1/service/aic/'

.EXAMPLE
$env:HOST = 'aiahk-dslab-dev.aiaazure.biz'
$env:GW_NS = 'nsp-hk01-d-intl-aic01'
$env:GW = 'gateway-nsp-hk01-d-intl-aic01-controller'
.\find-aks-istio-request-resources.ps1 -DumpXds
#>
[CmdletBinding()]
param(
    [Parameter()]
    [Alias('Host')]
    [string]$HostName,

    [Parameter()]
    [string]$LoadBalancerIp,

    [Parameter()]
    [string]$Scheme,

    [Parameter()]
    [string]$Port,

    [Parameter()]
    [string]$RequestMethod,

    [Parameter()]
    [string]$RequestPath,

    [Parameter()]
    [string]$GatewayNamespace,

    [Parameter()]
    [string]$GatewayName,

    [Parameter()]
    [string]$IstioRootNamespace,

    [Parameter()]
    [string]$IstioControlPlaneNamespace,

    [Parameter()]
    [string]$IstioRevision,

    [Parameter()]
    [switch]$DumpXds
)

$ErrorActionPreference = 'Stop'
$script:BoundParameterNames = @($PSBoundParameters.Keys)
$script:ScriptVersion = '2026.08.11.2'

function Write-Stderr {
    param(
        [AllowEmptyString()]
        [string]$Message
    )

    [Console]::Error.WriteLine($Message)
}

function Write-Section {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    Write-Output ''
    Write-Output ("==== {0} ====" -f $Name)
}

function Write-WarnLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Stderr ("WARN: {0}" -f $Message)
}

function Stop-Script {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [int]$ExitCode = 1
    )

    Write-Stderr ("ERROR: {0}" -f $Message)
    exit $ExitCode
}

function Get-Array {
    param(
        $Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        return @($Value)
    }

    return @($Value)
}

function Get-ObjectValue {
    param(
        $Object,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    return $property.Value
}

function Get-ObjectNames {
    param(
        $Object
    )

    if ($null -eq $Object) {
        return @()
    }

    if ($Object -is [System.Collections.IDictionary]) {
        return @($Object.Keys)
    }

    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Resolve-StringParameter {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParameterName,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName,

        [AllowNull()]
        [string]$DefaultValue = $null
    )

    if ($script:BoundParameterNames -contains $ParameterName) {
        return [string](Get-Variable -Name $ParameterName -Scope Script -ValueOnly)
    }

    $environmentValue = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if (-not [string]::IsNullOrEmpty($environmentValue)) {
        return [string]$environmentValue
    }

    return $DefaultValue
}

function ConvertTo-BooleanValue {
    param(
        [AllowNull()]
        [string]$Value,

        [bool]$DefaultValue = $false,

        [string]$SourceName = 'value'
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $DefaultValue
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        'true' { return $true }
        '1' { return $true }
        'yes' { return $true }
        'on' { return $true }
        'false' { return $false }
        '0' { return $false }
        'no' { return $false }
        'off' { return $false }
        default {
            Stop-Script -Message ("{0} must be a boolean value (true/false): {1}" -f $SourceName, $Value)
        }
    }
}

function Resolve-DumpXdsValue {
    if ($script:BoundParameterNames -contains 'DumpXds') {
        return [bool]$DumpXds.IsPresent
    }

    return ConvertTo-BooleanValue -Value ([Environment]::GetEnvironmentVariable('DUMP_XDS')) -DefaultValue $false -SourceName 'DUMP_XDS'
}

function Show-ValidationExamples {
    $lines = @(
        'Set the request information before running this script:',
        '',
        "  `$env:HOST='aiahk-dslab-dev.aiaazure.biz'",
        "  `$env:SCHEME='https'",
        "  `$env:PORT='443'",
        "  `$env:REQ_METHOD='GET'",
        "  `$env:REQ_PATH='/api/v1/service/aic/'",
        '',
        'To discover the Gateway from its address:',
        '',
        "  `$env:LB_IP='10.240.0.6'",
        '',
        'Or provide the Gateway explicitly instead of LoadBalancerIp:',
        '',
        "  `$env:GW_NS='nsp-hk01-d-intl-aic01'",
        "  `$env:GW='gateway-nsp-hk01-d-intl-aic01-controller'",
        '',
        'Or use named parameters:',
        '',
        "  .\find-aks-istio-request-resources.ps1 -HostName 'aiahk-dslab-dev.aiaazure.biz' -LoadBalancerIp '10.240.0.6'",
        '',
        'Then run:',
        '',
        '  .\find-aks-istio-request-resources.ps1'
    )

    foreach ($line in $lines) {
        Write-Stderr $line
    }
}

function Format-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName,

        [string[]]$ArgumentList = @()
    )

    $parts = @($CommandName) + (Get-Array $ArgumentList)
    $formatted = foreach ($part in $parts) {
        $text = [string]$part
        if ($text -match '\s') {
            "'" + ($text -replace "'", "''") + "'"
        }
        else {
            $text
        }
    }

    return ($formatted -join ' ')
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName,

        [string[]]$ArgumentList = @(),

        [switch]$AllowFailure
    )

    $rawOutput = & $CommandName @ArgumentList
    $exitCode = $LASTEXITCODE
    $lines = @($rawOutput | ForEach-Object { [string]$_ })
    $text = [string]::Join([Environment]::NewLine, $lines)
    $result = [pscustomobject]@{
        Command  = Format-NativeCommand -CommandName $CommandName -ArgumentList $ArgumentList
        ExitCode = $exitCode
        Output   = $lines
        Text     = $text
    }

    if (($exitCode -ne 0) -and -not $AllowFailure) {
        Stop-Script -Message ("Command failed with exit code {0}: {1}" -f $exitCode, $result.Command)
    }

    return $result
}

function Invoke-KubectlJson {
    param(
        [string[]]$KubectlArgumentList = @(),

        [switch]$AllowFailure,

        $FallbackObject = $null,

        [string]$FailureWarning = ''
    )

    if ($KubectlArgumentList.Count -eq 0) {
        Stop-Script -Message 'Internal error: Invoke-KubectlJson received an empty kubectl argument list.'
    }

    $result = Invoke-NativeCommand -CommandName 'kubectl' -ArgumentList $KubectlArgumentList -AllowFailure:$AllowFailure

    if ($result.ExitCode -ne 0) {
        if ($AllowFailure) {
            if (-not [string]::IsNullOrWhiteSpace($FailureWarning)) {
                Write-WarnLine $FailureWarning
            }

            return $FallbackObject
        }
    }

    if ([string]::IsNullOrWhiteSpace($result.Text)) {
        return [pscustomobject]@{}
    }

    try {
        return ($result.Text | ConvertFrom-Json)
    }
    catch {
        Stop-Script -Message ("Failed to parse JSON from command: {0}`n{1}" -f $result.Command, $_.Exception.Message)
    }
}

function Write-Table {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows,

        [string[]]$PropertyOrder = @()
    )

    $rowArray = @(Get-Array $Rows)
    if ($rowArray.Count -eq 0) {
        return
    }

    $tableText = $rowArray |
        Format-Table -Property $PropertyOrder -AutoSize |
        Out-String -Width 4096

    if (-not [string]::IsNullOrWhiteSpace($tableText)) {
        Write-Output $tableText.TrimEnd()
    }
}

function Test-HostnameMatch {
    param(
        [AllowNull()]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [string]$RequestedHost
    )

    $hostLower = $RequestedHost.ToLowerInvariant()

    # PowerShell coerces an omitted/null value to an empty string for a
    # [string] parameter. Gateway API treats an omitted listener hostname as
    # matching every hostname.
    if ([string]::IsNullOrEmpty($Pattern)) {
        return $true
    }

    $configured = $Pattern.ToLowerInvariant()
    if ($configured -eq $hostLower) {
        return $true
    }

    if ($configured.StartsWith('*.')) {
        $suffix = $configured.Substring(1)
        $apex = $configured.Substring(2)
        return $hostLower.EndsWith($suffix) -and ($hostLower -ne $apex)
    }

    return $false
}

function Test-HostnameListMatch {
    param(
        [object[]]$Hostnames,

        [Parameter(Mandatory = $true)]
        [string]$RequestedHost
    )

    $hostnameArray = @(Get-Array $Hostnames)
    if ($hostnameArray.Count -eq 0) {
        return $true
    }

    foreach ($hostname in $hostnameArray) {
        if (Test-HostnameMatch -Pattern ([string]$hostname) -RequestedHost $RequestedHost) {
            return $true
        }
    }

    return $false
}

function Normalize-PrefixPath {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$PathValue
    )

    if ($PathValue -eq '/') {
        return $PathValue
    }

    return ($PathValue -replace '/+$', '')
}

function Test-PathMatch {
    param(
        $ConfiguredPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RequestedPath
    )

    $pathType = [string](Get-ObjectValue -Object $ConfiguredPath -Name 'type' -Default 'PathPrefix')
    $pathValue = [string](Get-ObjectValue -Object $ConfiguredPath -Name 'value' -Default '/')

    switch ($pathType) {
        'Exact' {
            return ($RequestedPath -eq $pathValue)
        }
        'PathPrefix' {
            $prefix = Normalize-PrefixPath -PathValue $pathValue
            $request = Normalize-PrefixPath -PathValue $RequestedPath
            return ($prefix -eq '/') -or ($request -eq $prefix) -or $request.StartsWith($prefix + '/')
        }
        'RegularExpression' {
            try {
                return [System.Text.RegularExpressions.Regex]::IsMatch(
                    $RequestedPath,
                    $pathValue,
                    [System.Text.RegularExpressions.RegexOptions]::None
                )
            }
            catch {
                return $false
            }
        }
        default {
            return $false
        }
    }
}

function Get-UniqueStrings {
    param(
        [object[]]$Values
    )

    $result = New-Object System.Collections.Generic.List[string]
    foreach ($value in (Get-Array $Values)) {
        if ($null -eq $value) {
            continue
        }

        $text = [string]$value
        if ($text -eq '') {
            continue
        }

        if (-not $result.Contains($text)) {
            [void]$result.Add($text)
        }
    }

    return @($result)
}

function Test-ParentRefMatchesGateway {
    param(
        $Route,
        $ParentRef,
        [Parameter(Mandatory = $true)]
        [string]$GatewayName,
        [Parameter(Mandatory = $true)]
        [string]$GatewayNamespace,
        [string[]]$ListenerNames = @()
    )

    if ([string](Get-ObjectValue -Object $ParentRef -Name 'name') -ne $GatewayName) {
        return $false
    }

    $routeNamespace = [string](Get-ObjectValue -Object (Get-ObjectValue -Object $Route -Name 'metadata') -Name 'namespace')
    $parentNamespace = Get-ObjectValue -Object $ParentRef -Name 'namespace'
    if ($null -eq $parentNamespace) {
        $parentNamespace = $routeNamespace
    }

    if ([string]$parentNamespace -ne $GatewayNamespace) {
        return $false
    }

    if ([string](Get-ObjectValue -Object $ParentRef -Name 'group' -Default 'gateway.networking.k8s.io') -ne 'gateway.networking.k8s.io') {
        return $false
    }

    if ([string](Get-ObjectValue -Object $ParentRef -Name 'kind' -Default 'Gateway') -ne 'Gateway') {
        return $false
    }

    $sectionName = Get-ObjectValue -Object $ParentRef -Name 'sectionName'
    if ($null -eq $sectionName) {
        return $true
    }

    return (@($ListenerNames) -contains [string]$sectionName)
}

function Get-AcceptedStatus {
    param(
        $Route,
        [Parameter(Mandatory = $true)]
        [string]$GatewayName,
        [Parameter(Mandatory = $true)]
        [string]$GatewayNamespace,
        [string[]]$ListenerNames = @()
    )

    $status = Get-ObjectValue -Object $Route -Name 'status'
    foreach ($statusParent in (Get-Array (Get-ObjectValue -Object $status -Name 'parents'))) {
        $parentRef = Get-ObjectValue -Object $statusParent -Name 'parentRef'
        if (-not (Test-ParentRefMatchesGateway -Route $Route -ParentRef $parentRef -GatewayName $GatewayName -GatewayNamespace $GatewayNamespace -ListenerNames $ListenerNames)) {
            continue
        }

        foreach ($condition in (Get-Array (Get-ObjectValue -Object $statusParent -Name 'conditions'))) {
            if ([string](Get-ObjectValue -Object $condition -Name 'type') -eq 'Accepted') {
                $acceptedStatus = Get-ObjectValue -Object $condition -Name 'status'
                if ($null -ne $acceptedStatus) {
                    return [string]$acceptedStatus
                }
            }
        }
    }

    return 'Unknown'
}

function Get-MatchingParentSections {
    param(
        $Route,
        [Parameter(Mandatory = $true)]
        [string]$GatewayName,
        [Parameter(Mandatory = $true)]
        [string]$GatewayNamespace,
        [string[]]$ListenerNames = @()
    )

    $sections = New-Object System.Collections.Generic.List[string]
    foreach ($parentRef in (Get-Array (Get-ObjectValue -Object (Get-ObjectValue -Object $Route -Name 'spec') -Name 'parentRefs'))) {
        if (-not (Test-ParentRefMatchesGateway -Route $Route -ParentRef $parentRef -GatewayName $GatewayName -GatewayNamespace $GatewayNamespace -ListenerNames $ListenerNames)) {
            continue
        }

        $sectionName = Get-ObjectValue -Object $parentRef -Name 'sectionName'
        if ($null -eq $sectionName) {
            $sectionName = '*'
        }

        [void]$sections.Add([string]$sectionName)
    }

    return ((Get-UniqueStrings -Values $sections) -join ',')
}

function Test-SelectorMatchesLabels {
    param(
        $Selector,
        $Labels
    )

    $selectorNames = @(Get-ObjectNames $Selector)
    if ($selectorNames.Count -eq 0) {
        return $true
    }

    foreach ($name in $selectorNames) {
        if ((Get-ObjectValue -Object $Labels -Name $name) -ne (Get-ObjectValue -Object $Selector -Name $name)) {
            return $false
        }
    }

    return $true
}

function Test-SelectorMatchesAnyPod {
    param(
        $Selector,
        [object[]]$PodRecords
    )

    $pods = @(Get-Array $PodRecords)
    if ($pods.Count -eq 0) {
        return $false
    }

    foreach ($pod in $pods) {
        if (Test-SelectorMatchesLabels -Selector $Selector -Labels (Get-ObjectValue -Object $pod -Name 'Labels')) {
            return $true
        }
    }

    return $false
}

function Test-SelectorMatchesPodNamespace {
    param(
        $Selector,
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [object[]]$PodRecords
    )

    $pods = @(Get-Array $PodRecords)
    if ($pods.Count -eq 0) {
        return $false
    }

    foreach ($pod in $pods) {
        if (
            ([string](Get-ObjectValue -Object $pod -Name 'Namespace') -eq $Namespace) -and
            (Test-SelectorMatchesLabels -Selector $Selector -Labels (Get-ObjectValue -Object $pod -Name 'Labels'))
        ) {
            return $true
        }
    }

    return $false
}

function Get-ConfigPatchContext {
    param(
        $ConfigPatch
    )

    $match = Get-ObjectValue -Object $ConfigPatch -Name 'match'
    $context = Get-ObjectValue -Object $match -Name 'context'
    if ($null -eq $context) {
        return 'ANY'
    }

    return [string]$context
}

function Get-ConfigPatchListenerPort {
    param(
        $ConfigPatch
    )

    $match = Get-ObjectValue -Object $ConfigPatch -Name 'match'
    $listener = Get-ObjectValue -Object $match -Name 'listener'
    return Get-ObjectValue -Object $listener -Name 'portNumber'
}

function Test-EnvoyFilterHasRelevantConfigPatch {
    param(
        $EnvoyFilter,
        [Parameter(Mandatory = $true)]
        [int]$RequestPort
    )

    foreach ($configPatch in (Get-Array (Get-ObjectValue -Object (Get-ObjectValue -Object $EnvoyFilter -Name 'spec') -Name 'configPatches'))) {
        $context = Get-ConfigPatchContext -ConfigPatch $configPatch
        if (($context -ne 'ANY') -and ($context -ne 'GATEWAY')) {
            continue
        }

        $listenerPort = Get-ConfigPatchListenerPort -ConfigPatch $configPatch
        if (($null -eq $listenerPort) -or ([string]$listenerPort -eq [string]$RequestPort)) {
            return $true
        }
    }

    return $false
}

function Get-EnvoyFilterApplicableScope {
    param(
        $EnvoyFilter,
        [Parameter(Mandatory = $true)]
        [string]$GatewayName,
        [Parameter(Mandatory = $true)]
        [string]$GatewayNamespace,
        [Parameter(Mandatory = $true)]
        [string]$GatewayClassName,
        [Parameter(Mandatory = $true)]
        [string]$RootNamespace,
        [object[]]$PodRecords
    )

    $metadata = Get-ObjectValue -Object $EnvoyFilter -Name 'metadata'
    $spec = Get-ObjectValue -Object $EnvoyFilter -Name 'spec'
    $envoyFilterNamespace = [string](Get-ObjectValue -Object $metadata -Name 'namespace')
    $targetRefs = @(Get-Array (Get-ObjectValue -Object $spec -Name 'targetRefs'))
    $workloadSelector = Get-ObjectValue -Object $spec -Name 'workloadSelector'
    $selectorLabels = Get-ObjectValue -Object $workloadSelector -Name 'labels'

    $targetsGateway = $false
    foreach ($targetRef in $targetRefs) {
        if (
            ($envoyFilterNamespace -eq $GatewayNamespace) -and
            ([string](Get-ObjectValue -Object $targetRef -Name 'group' -Default '') -eq 'gateway.networking.k8s.io') -and
            ([string](Get-ObjectValue -Object $targetRef -Name 'kind') -eq 'Gateway') -and
            ([string](Get-ObjectValue -Object $targetRef -Name 'name') -eq $GatewayName)
        ) {
            $targetsGateway = $true
            break
        }
    }

    if ($targetsGateway) {
        return 'targetRef:Gateway'
    }

    $targetsGatewayClass = $false
    foreach ($targetRef in $targetRefs) {
        if (
            ([string](Get-ObjectValue -Object $targetRef -Name 'group' -Default '') -eq 'gateway.networking.k8s.io') -and
            ([string](Get-ObjectValue -Object $targetRef -Name 'kind') -eq 'GatewayClass') -and
            ([string](Get-ObjectValue -Object $targetRef -Name 'name') -eq $GatewayClassName)
        ) {
            $targetsGatewayClass = $true
            break
        }
    }

    if ($targetsGatewayClass -and ($envoyFilterNamespace -eq $RootNamespace)) {
        return 'targetRef:GatewayClass'
    }

    if ($targetRefs.Count -gt 0) {
        return $null
    }

    if (($envoyFilterNamespace -eq $RootNamespace) -and (Test-SelectorMatchesAnyPod -Selector $selectorLabels -PodRecords $PodRecords)) {
        if ($null -eq $workloadSelector) {
            return 'mesh-root-wide'
        }

        return 'mesh-root-workloadSelector'
    }

    if (Test-SelectorMatchesPodNamespace -Selector $selectorLabels -Namespace $envoyFilterNamespace -PodRecords $PodRecords) {
        if ($null -eq $workloadSelector) {
            return 'pod-namespace-wide'
        }

        return 'pod-workloadSelector'
    }

    return $null
}

function Invoke-OptionalDiagnosticCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName,

        [string[]]$ArgumentList = @()
    )

    $result = Invoke-NativeCommand -CommandName $CommandName -ArgumentList $ArgumentList -AllowFailure
    if (-not [string]::IsNullOrWhiteSpace($result.Text)) {
        Write-Output $result.Text.TrimEnd()
    }

    if ($result.ExitCode -ne 0) {
        Write-WarnLine ("Command failed with exit code {0}: {1}" -f $result.ExitCode, $result.Command)
    }
}

$EffectiveHostName = Resolve-StringParameter -ParameterName 'HostName' -EnvironmentName 'HOST'
$EffectiveLoadBalancerIp = Resolve-StringParameter -ParameterName 'LoadBalancerIp' -EnvironmentName 'LB_IP'
$EffectiveScheme = Resolve-StringParameter -ParameterName 'Scheme' -EnvironmentName 'SCHEME' -DefaultValue 'https'
$EffectivePort = Resolve-StringParameter -ParameterName 'Port' -EnvironmentName 'PORT' -DefaultValue '443'
$EffectiveRequestMethod = Resolve-StringParameter -ParameterName 'RequestMethod' -EnvironmentName 'REQ_METHOD' -DefaultValue 'GET'
$EffectiveRequestPath = Resolve-StringParameter -ParameterName 'RequestPath' -EnvironmentName 'REQ_PATH' -DefaultValue '/'
$EffectiveGatewayNamespace = Resolve-StringParameter -ParameterName 'GatewayNamespace' -EnvironmentName 'GW_NS'
$EffectiveGatewayName = Resolve-StringParameter -ParameterName 'GatewayName' -EnvironmentName 'GW'
$EffectiveIstioRootNamespace = Resolve-StringParameter -ParameterName 'IstioRootNamespace' -EnvironmentName 'ISTIO_ROOT_NS' -DefaultValue 'aks-istio-system'
$EffectiveIstioControlPlaneNamespace = Resolve-StringParameter -ParameterName 'IstioControlPlaneNamespace' -EnvironmentName 'ISTIO_CONTROL_PLANE_NS' -DefaultValue 'aks-istio-system'
$EffectiveIstioRevision = Resolve-StringParameter -ParameterName 'IstioRevision' -EnvironmentName 'ISTIO_REVISION'
$EffectiveDumpXds = Resolve-DumpXdsValue

$EffectiveRequestPath = $EffectiveRequestPath -replace "`r", ''
$EffectiveRequestPath = $EffectiveRequestPath -replace "`n", ''
$EffectiveRequestPath = $EffectiveRequestPath -replace ([string][char]0x00A0), ''

$missingInputs = New-Object System.Collections.Generic.List[string]
if ([string]::IsNullOrWhiteSpace($EffectiveHostName)) {
    [void]$missingInputs.Add('HostName')
}

$hasExplicitGatewayNamespace = -not [string]::IsNullOrWhiteSpace($EffectiveGatewayNamespace)
$hasExplicitGatewayName = -not [string]::IsNullOrWhiteSpace($EffectiveGatewayName)

if ($hasExplicitGatewayNamespace -or $hasExplicitGatewayName) {
    if (-not ($hasExplicitGatewayNamespace -and $hasExplicitGatewayName)) {
        Write-Stderr 'ERROR: GatewayNamespace and GatewayName must be provided together.'
        Write-Stderr ''
        Write-Stderr 'Example:'
        Write-Stderr "  `$env:GW_NS='nsp-hk01-d-intl-aic01'"
        Write-Stderr "  `$env:GW='gateway-nsp-hk01-d-intl-aic01-controller'"
        Write-Stderr ''
        Write-Stderr "  .\find-aks-istio-request-resources.ps1 -GatewayNamespace 'nsp-hk01-d-intl-aic01' -GatewayName 'gateway-nsp-hk01-d-intl-aic01-controller' -HostName 'aiahk-dslab-dev.aiaazure.biz'"
        exit 2
    }
}
elseif ([string]::IsNullOrWhiteSpace($EffectiveLoadBalancerIp)) {
    [void]$missingInputs.Add('LoadBalancerIp')
}

if ($missingInputs.Count -gt 0) {
    Write-Stderr ("ERROR: Missing required input(s): {0}" -f ($missingInputs -join ', '))
    Write-Stderr ''
    Show-ValidationExamples
    exit 2
}

if (-not (Get-Command -Name 'kubectl' -ErrorAction SilentlyContinue)) {
    Stop-Script -Message 'Required command not found: kubectl'
}

if ($EffectivePort -notmatch '^[0-9]+$') {
    Stop-Script -Message ("Port must be numeric: {0}" -f $EffectivePort)
}

$EffectivePortNumber = [int]$EffectivePort

switch ($EffectiveScheme.ToLowerInvariant()) {
    'https' {
        $ListenerProtocol = 'HTTPS'
    }
    'http' {
        $ListenerProtocol = 'HTTP'
    }
    default {
        Stop-Script -Message ("Scheme must be http or https: {0}" -f $EffectiveScheme)
    }
}

$currentContext = 'unknown'
$contextOutput = & kubectl config current-context 2>$null
if (($LASTEXITCODE -eq 0) -and $contextOutput) {
    $currentContext = ([string]::Join([Environment]::NewLine, @($contextOutput))).Trim()
}

Write-Section -Name 'Request'
Write-Output ("Script:  {0}" -f $script:ScriptVersion)
Write-Output ("PS:      {0}" -f $PSVersionTable.PSVersion)
Write-Output ("Method:  {0}" -f $EffectiveRequestMethod)
Write-Output ("URL:     {0}://{1}:{2}{3}" -f $EffectiveScheme, $EffectiveHostName, $EffectivePort, $EffectiveRequestPath)
if ([string]::IsNullOrWhiteSpace($EffectiveLoadBalancerIp)) {
    Write-Output 'LB IP:   not provided; using explicit Gateway'
}
else {
    Write-Output ("LB IP:   {0}" -f $EffectiveLoadBalancerIp)
}
Write-Output ("Context: {0}" -f $currentContext)

Write-Section -Name 'DNS'
$dnsFallback = if (-not [string]::IsNullOrWhiteSpace($EffectiveLoadBalancerIp)) {
    "LB_IP=$EffectiveLoadBalancerIp"
}
else {
    'the explicit Gateway'
}

$dnsLookupCompleted = $false
if (Get-Command -Name 'Resolve-DnsName' -ErrorAction SilentlyContinue) {
    try {
        $dnsResult = Resolve-DnsName -Name $EffectiveHostName
        $dnsText = $dnsResult | Format-Table -AutoSize | Out-String -Width 4096
        if (-not [string]::IsNullOrWhiteSpace($dnsText)) {
            Write-Output $dnsText.TrimEnd()
        }
        $dnsLookupCompleted = $true
    }
    catch {
        if (Get-Command -Name 'nslookup' -ErrorAction SilentlyContinue) {
            $nslookupResult = Invoke-NativeCommand -CommandName 'nslookup' -ArgumentList @($EffectiveHostName) -AllowFailure
            if ($nslookupResult.ExitCode -eq 0) {
                if (-not [string]::IsNullOrWhiteSpace($nslookupResult.Text)) {
                    Write-Output $nslookupResult.Text.TrimEnd()
                }
                $dnsLookupCompleted = $true
            }
        }
    }
}

if (-not $dnsLookupCompleted) {
    if (Get-Command -Name 'nslookup' -ErrorAction SilentlyContinue) {
    $nslookupResult = Invoke-NativeCommand -CommandName 'nslookup' -ArgumentList @($EffectiveHostName) -AllowFailure
        if ($nslookupResult.ExitCode -eq 0) {
            if (-not [string]::IsNullOrWhiteSpace($nslookupResult.Text)) {
                Write-Output $nslookupResult.Text.TrimEnd()
            }
            $dnsLookupCompleted = $true
        }
    }
}

if (-not $dnsLookupCompleted) {
    if ((Get-Command -Name 'Resolve-DnsName' -ErrorAction SilentlyContinue) -or (Get-Command -Name 'nslookup' -ErrorAction SilentlyContinue)) {
        Write-WarnLine ("DNS lookup failed; continuing with {0}" -f $dnsFallback)
    }
    else {
        Write-WarnLine 'Neither Resolve-DnsName nor nslookup is installed; skipping DNS lookup'
    }
}

Write-Section -Name 'Collecting cluster resources'
$gatewaysResponse = Invoke-KubectlJson -KubectlArgumentList @('get', 'gateways.gateway.networking.k8s.io', '-A', '-o', 'json')
$httpRoutesResponse = Invoke-KubectlJson -KubectlArgumentList @('get', 'httproutes.gateway.networking.k8s.io', '-A', '-o', 'json')
$envoyFiltersResponse = Invoke-KubectlJson `
    -KubectlArgumentList @('get', 'envoyfilters.networking.istio.io', '-A', '-o', 'json') `
    -AllowFailure `
    -FallbackObject ([pscustomobject]@{ items = @() }) `
    -FailureWarning 'EnvoyFilter CRD was not found or could not be listed'

$matchedGateways = New-Object System.Collections.Generic.List[object]
foreach ($gateway in (Get-Array (Get-ObjectValue -Object $gatewaysResponse -Name 'items'))) {
    $metadata = Get-ObjectValue -Object $gateway -Name 'metadata'
    $spec = Get-ObjectValue -Object $gateway -Name 'spec'
    $status = Get-ObjectValue -Object $gateway -Name 'status'
    $gatewayNamespace = [string](Get-ObjectValue -Object $metadata -Name 'namespace')
    $gatewayName = [string](Get-ObjectValue -Object $metadata -Name 'name')

    $matchesGateway = $false
    if ($hasExplicitGatewayNamespace -or $hasExplicitGatewayName) {
        $matchesGateway = ($gatewayNamespace -eq $EffectiveGatewayNamespace) -and ($gatewayName -eq $EffectiveGatewayName)
    }
    else {
        foreach ($address in (Get-Array (Get-ObjectValue -Object $status -Name 'addresses'))) {
            if ([string](Get-ObjectValue -Object $address -Name 'value') -eq $EffectiveLoadBalancerIp) {
                $matchesGateway = $true
                break
            }
        }
    }

    if (-not $matchesGateway) {
        continue
    }

    [void]$matchedGateways.Add($gateway)
}

if ($matchedGateways.Count -eq 0) {
    $gatewayQualifier = ''
    if (-not [string]::IsNullOrWhiteSpace($EffectiveGatewayName)) {
        $gatewayQualifier = " and GW=$EffectiveGatewayNamespace/$EffectiveGatewayName"
    }

    Stop-Script -Message ("No Gateway was found for LB_IP={0}{1}" -f $EffectiveLoadBalancerIp, $gatewayQualifier)
}

Write-Section -Name 'Matched Gateways'
$matchedGatewayRows = foreach ($gateway in $matchedGateways) {
    $metadata = Get-ObjectValue -Object $gateway -Name 'metadata'
    $spec = Get-ObjectValue -Object $gateway -Name 'spec'
    $status = Get-ObjectValue -Object $gateway -Name 'status'
    $addresses = foreach ($address in (Get-Array (Get-ObjectValue -Object $status -Name 'addresses'))) {
        [string](Get-ObjectValue -Object $address -Name 'value')
    }

    [pscustomobject][ordered]@{
        NAMESPACE     = [string](Get-ObjectValue -Object $metadata -Name 'namespace')
        GATEWAY       = [string](Get-ObjectValue -Object $metadata -Name 'name')
        GATEWAY_CLASS = [string](Get-ObjectValue -Object $spec -Name 'gatewayClassName')
        ADDRESSES     = ($addresses -join ',')
    }
}
Write-Table -Rows @($matchedGatewayRows) -PropertyOrder @('NAMESPACE', 'GATEWAY', 'GATEWAY_CLASS', 'ADDRESSES')

function Process-Gateway {
    param(
        [Parameter(Mandatory = $true)]
        $Gateway
    )

    $metadata = Get-ObjectValue -Object $Gateway -Name 'metadata'
    $spec = Get-ObjectValue -Object $Gateway -Name 'spec'
    $gatewayNamespace = [string](Get-ObjectValue -Object $metadata -Name 'namespace')
    $gatewayName = [string](Get-ObjectValue -Object $metadata -Name 'name')
    $gatewayClassName = [string](Get-ObjectValue -Object $spec -Name 'gatewayClassName')

    Write-Section -Name ("Gateway {0}/{1}" -f $gatewayNamespace, $gatewayName)
    $gatewayWideResult = Invoke-NativeCommand -CommandName 'kubectl' -ArgumentList @('get', 'gateway', '-n', $gatewayNamespace, $gatewayName, '-o', 'wide')
    if (-not [string]::IsNullOrWhiteSpace($gatewayWideResult.Text)) {
        Write-Output $gatewayWideResult.Text.TrimEnd()
    }

    $listenerMatches = New-Object System.Collections.Generic.List[object]
    foreach ($listener in (Get-Array (Get-ObjectValue -Object $spec -Name 'listeners'))) {
        $listenerPort = Get-ObjectValue -Object $listener -Name 'port'
        if ($null -eq $listenerPort) {
            continue
        }

        if ([string]$listenerPort -ne [string]$EffectivePortNumber) {
            continue
        }

        if ([string](Get-ObjectValue -Object $listener -Name 'protocol') -ne $ListenerProtocol) {
            continue
        }

        if (-not (Test-HostnameMatch -Pattern (Get-ObjectValue -Object $listener -Name 'hostname') -RequestedHost $EffectiveHostName)) {
            continue
        }

        [void]$listenerMatches.Add(
            [pscustomobject][ordered]@{
                NAME      = [string](Get-ObjectValue -Object $listener -Name 'name')
                PROTOCOL  = [string](Get-ObjectValue -Object $listener -Name 'protocol')
                PORT      = [string](Get-ObjectValue -Object $listener -Name 'port')
                HOSTNAME  = if ($null -eq (Get-ObjectValue -Object $listener -Name 'hostname')) { '*' } else { [string](Get-ObjectValue -Object $listener -Name 'hostname') }
                RAW       = $listener
            }
        )
    }

    Write-Section -Name 'Matching Listeners'
    if ($listenerMatches.Count -eq 0) {
        Write-WarnLine ("No listener matches protocol={0} port={1} host={2}" -f $ListenerProtocol, $EffectivePortNumber, $EffectiveHostName)
        return
    }

    Write-Table -Rows $listenerMatches.ToArray() -PropertyOrder @('NAME', 'PROTOCOL', 'PORT', 'HOSTNAME')
    $listenerNames = @($listenerMatches | ForEach-Object { $_.NAME })

    $routeMatches = New-Object System.Collections.Generic.List[object]
    foreach ($route in (Get-Array (Get-ObjectValue -Object $httpRoutesResponse -Name 'items'))) {
        $routeMetadata = Get-ObjectValue -Object $route -Name 'metadata'
        $routeSpec = Get-ObjectValue -Object $route -Name 'spec'
        $routeNamespace = [string](Get-ObjectValue -Object $routeMetadata -Name 'namespace')
        $routeName = [string](Get-ObjectValue -Object $routeMetadata -Name 'name')

        $matchingParents = New-Object System.Collections.Generic.List[object]
        foreach ($parentRef in (Get-Array (Get-ObjectValue -Object $routeSpec -Name 'parentRefs'))) {
            if (Test-ParentRefMatchesGateway -Route $route -ParentRef $parentRef -GatewayName $gatewayName -GatewayNamespace $gatewayNamespace -ListenerNames $listenerNames) {
                [void]$matchingParents.Add($parentRef)
            }
        }

        if ($matchingParents.Count -eq 0) {
            continue
        }

        $routeHostnames = @(Get-Array (Get-ObjectValue -Object $routeSpec -Name 'hostnames'))
        if (-not (Test-HostnameListMatch -Hostnames $routeHostnames -RequestedHost $EffectiveHostName)) {
            continue
        }

        $rules = @(Get-Array (Get-ObjectValue -Object $routeSpec -Name 'rules'))
        for ($ruleIndex = 0; $ruleIndex -lt $rules.Count; $ruleIndex++) {
            $rule = $rules[$ruleIndex]
            $matches = @(Get-Array (Get-ObjectValue -Object $rule -Name 'matches'))
            if ($matches.Count -eq 0) {
                $matches = @([pscustomobject]@{})
            }

            foreach ($match in $matches) {
                $matchMethod = Get-ObjectValue -Object $match -Name 'method'
                if (($null -ne $matchMethod) -and ([string]$matchMethod -ne $EffectiveRequestMethod)) {
                    continue
                }

                $pathObject = Get-ObjectValue -Object $match -Name 'path'
                if (-not (Test-PathMatch -ConfiguredPath $pathObject -RequestedPath $EffectiveRequestPath)) {
                    continue
                }

                $accepted = Get-AcceptedStatus -Route $route -GatewayName $gatewayName -GatewayNamespace $gatewayNamespace -ListenerNames $listenerNames
                $headers = @(Get-Array (Get-ObjectValue -Object $match -Name 'headers'))
                $queryParams = @(Get-Array (Get-ObjectValue -Object $match -Name 'queryParams'))
                $hasExtra = ($headers.Count -gt 0) -or ($queryParams.Count -gt 0)

                $backendRefs = foreach ($backendRef in (Get-Array (Get-ObjectValue -Object $rule -Name 'backendRefs'))) {
                    $backendNamespace = Get-ObjectValue -Object $backendRef -Name 'namespace'
                    if ($null -eq $backendNamespace) {
                        $backendNamespace = $routeNamespace
                    }

                    "{0}/{1}:{2}(weight={3})" -f `
                        [string]$backendNamespace, `
                        [string](Get-ObjectValue -Object $backendRef -Name 'name'), `
                        [string](Get-ObjectValue -Object $backendRef -Name 'port' -Default '-'), `
                        [string](Get-ObjectValue -Object $backendRef -Name 'weight' -Default 1)
                }

                $resultType = 'MATCH'
                if ($accepted -eq 'False') {
                    $resultType = 'NOT_ACCEPTED'
                }
                elseif ($accepted -ne 'True') {
                    $resultType = 'STATUS_UNKNOWN'
                }
                elseif ($hasExtra) {
                    $resultType = 'CHECK_EXTRA'
                }

                $hostnamesText = if ($routeHostnames.Count -eq 0) {
                    '*'
                }
                else {
                    (@($routeHostnames | ForEach-Object { [string]$_ }) -join ',')
                }

                $extraText = '-'
                if ($hasExtra) {
                    $extraText = "headers={0},queryParams={1}" -f $headers.Count, $queryParams.Count
                }

                [void]$routeMatches.Add(
                    [pscustomobject][ordered]@{
                        RESULT     = $resultType
                        ROUTE_NS   = $routeNamespace
                        HTTPROUTE  = $routeName
                        RULE       = ("rule[{0}]" -f $ruleIndex)
                        ACCEPTED   = $accepted
                        LISTENER   = Get-MatchingParentSections -Route $route -GatewayName $gatewayName -GatewayNamespace $gatewayNamespace -ListenerNames $listenerNames
                        HOSTNAMES  = $hostnamesText
                        METHOD     = if ($null -eq $matchMethod) { '*' } else { [string]$matchMethod }
                        PATH_TYPE  = [string](Get-ObjectValue -Object $pathObject -Name 'type' -Default 'PathPrefix')
                        PATH       = [string](Get-ObjectValue -Object $pathObject -Name 'value' -Default '/')
                        EXTRA      = $extraText
                        BACKENDS   = (@($backendRefs) -join ',')
                    }
                )
            }
        }
    }

    Write-Section -Name 'Matching HTTPRoutes'
    if ($routeMatches.Count -eq 0) {
        Write-WarnLine ("No HTTPRoute matches gateway={0}/{1} host={2} method={3} path={4}" -f $gatewayNamespace, $gatewayName, $EffectiveHostName, $EffectiveRequestMethod, $EffectiveRequestPath)
    }
    else {
        Write-Table -Rows $routeMatches.ToArray() -PropertyOrder @('RESULT', 'ROUTE_NS', 'HTTPROUTE', 'RULE', 'ACCEPTED', 'LISTENER', 'HOSTNAMES', 'METHOD', 'PATH_TYPE', 'PATH', 'EXTRA', 'BACKENDS')
    }

    Write-Section -Name 'Gateway Workload'
    $labelSelector = "gateway.networking.k8s.io/gateway-name=$gatewayName"
    $podsResponse = Invoke-KubectlJson `
        -KubectlArgumentList @('get', 'pods', '-n', $gatewayNamespace, '-l', $labelSelector, '-o', 'json') `
        -AllowFailure `
        -FallbackObject ([pscustomobject]@{ items = @() })
    $podSearchScope = 'namespace'

    if (@(Get-Array (Get-ObjectValue -Object $podsResponse -Name 'items')).Count -eq 0) {
        $podSearchScope = 'cluster'
        $podsResponse = Invoke-KubectlJson `
            -KubectlArgumentList @('get', 'pods', '-A', '-l', $labelSelector, '-o', 'json') `
            -AllowFailure `
            -FallbackObject ([pscustomobject]@{ items = @() })
    }

    $podItems = @(Get-Array (Get-ObjectValue -Object $podsResponse -Name 'items'))
    $podNames = foreach ($pod in $podItems) {
        $podMetadata = Get-ObjectValue -Object $pod -Name 'metadata'
        "{0}/{1}" -f [string](Get-ObjectValue -Object $podMetadata -Name 'namespace'), [string](Get-ObjectValue -Object $podMetadata -Name 'name')
    }

    $firstPod = $null
    $firstPodNamespace = $null
    $gatewayRevision = $null
    $gatewayResourceRevision = Get-ObjectValue `
        -Object (Get-ObjectValue -Object $metadata -Name 'labels') `
        -Name 'istio.io/rev'
    if ($podItems.Count -gt 0) {
        $firstPodMetadata = Get-ObjectValue -Object $podItems[0] -Name 'metadata'
        $firstPod = [string](Get-ObjectValue -Object $firstPodMetadata -Name 'name')
        $firstPodNamespace = [string](Get-ObjectValue -Object $firstPodMetadata -Name 'namespace')
        $gatewayRevision = Get-ObjectValue -Object (Get-ObjectValue -Object $firstPodMetadata -Name 'labels') -Name 'istio.io/rev'
    }

    $effectiveRevision = $EffectiveIstioRevision
    $revisionSource = 'explicit input'
    if ([string]::IsNullOrWhiteSpace($effectiveRevision)) {
        $effectiveRevision = $gatewayRevision
        $revisionSource = 'Gateway Pod label'
    }
    if ([string]::IsNullOrWhiteSpace($effectiveRevision)) {
        $effectiveRevision = $gatewayResourceRevision
        $revisionSource = 'Gateway resource label'
    }
    if ([string]::IsNullOrWhiteSpace($effectiveRevision)) {
        $istiodResponse = Invoke-KubectlJson `
            -KubectlArgumentList @(
                'get', 'pods',
                '-n', $EffectiveIstioControlPlaneNamespace,
                '-l', 'app=istiod',
                '-o', 'json'
            ) `
            -AllowFailure `
            -FallbackObject ([pscustomobject]@{ items = @() })

        $runningRevisions = foreach ($istiodPod in (Get-Array (Get-ObjectValue -Object $istiodResponse -Name 'items'))) {
            $istiodStatus = Get-ObjectValue -Object $istiodPod -Name 'status'
            if ([string](Get-ObjectValue -Object $istiodStatus -Name 'phase') -ne 'Running') {
                continue
            }

            $istiodMetadata = Get-ObjectValue -Object $istiodPod -Name 'metadata'
            $revision = Get-ObjectValue `
                -Object (Get-ObjectValue -Object $istiodMetadata -Name 'labels') `
                -Name 'istio.io/rev'

            if ([string]::IsNullOrWhiteSpace([string]$revision)) {
                $istiodName = [string](Get-ObjectValue -Object $istiodMetadata -Name 'name')
                if ($istiodName -match '^istiod-(asm-\d+-\d+)-') {
                    $revision = $Matches[1]
                }
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$revision)) {
                [string]$revision
            }
        }

        $uniqueRunningRevisions = @(Get-UniqueStrings -Values $runningRevisions)
        if ($uniqueRunningRevisions.Count -eq 1) {
            $effectiveRevision = $uniqueRunningRevisions[0]
            $revisionSource = 'only discovered istiod revision; proxy membership not yet verified'
        }
    }

    $podRecords = foreach ($pod in $podItems) {
        $podMetadata = Get-ObjectValue -Object $pod -Name 'metadata'
        [pscustomobject]@{
            Namespace = [string](Get-ObjectValue -Object $podMetadata -Name 'namespace')
            Labels    = Get-ObjectValue -Object $podMetadata -Name 'labels'
        }
    }

    if (@($podNames).Count -eq 0) {
        Write-WarnLine ("No Pod found with gateway.networking.k8s.io/gateway-name={0}" -f $gatewayName)
        Write-WarnLine 'For a manual deployment model, locate the gateway Service and use its selector to find the Envoy Pods'
    }
    else {
        Write-Output ("PODS: {0}" -f (@($podNames) -join ','))
        if ($podSearchScope -eq 'namespace') {
            $podWideResult = Invoke-NativeCommand -CommandName 'kubectl' -ArgumentList @('get', 'pods', '-n', $gatewayNamespace, '-l', $labelSelector, '-o', 'wide')
        }
        else {
            Write-WarnLine 'Gateway Pod was not found in the Gateway namespace; using cluster-wide label discovery'
            $podWideResult = Invoke-NativeCommand -CommandName 'kubectl' -ArgumentList @('get', 'pods', '-A', '-l', $labelSelector, '-o', 'wide')
        }

        if (-not [string]::IsNullOrWhiteSpace($podWideResult.Text)) {
            Write-Output $podWideResult.Text.TrimEnd()
        }
    }

    $envoyFilterMatches = New-Object System.Collections.Generic.List[object]
    foreach ($envoyFilter in (Get-Array (Get-ObjectValue -Object $envoyFiltersResponse -Name 'items'))) {
        $scope = Get-EnvoyFilterApplicableScope `
            -EnvoyFilter $envoyFilter `
            -GatewayName $gatewayName `
            -GatewayNamespace $gatewayNamespace `
            -GatewayClassName $gatewayClassName `
            -RootNamespace $EffectiveIstioRootNamespace `
            -PodRecords $podRecords

        if ([string]::IsNullOrWhiteSpace($scope)) {
            continue
        }

        if (-not (Test-EnvoyFilterHasRelevantConfigPatch -EnvoyFilter $envoyFilter -RequestPort $EffectivePortNumber)) {
            continue
        }

        $envoyFilterMetadata = Get-ObjectValue -Object $envoyFilter -Name 'metadata'
        $envoyFilterSpec = Get-ObjectValue -Object $envoyFilter -Name 'spec'
        $configPatches = @(Get-Array (Get-ObjectValue -Object $envoyFilterSpec -Name 'configPatches'))

        $contexts = foreach ($configPatch in $configPatches) {
            $context = Get-ConfigPatchContext -ConfigPatch $configPatch
            if (($context -eq 'ANY') -or ($context -eq 'GATEWAY')) {
                $context
            }
        }

        $applyToValues = foreach ($configPatch in $configPatches) {
            $applyTo = Get-ObjectValue -Object $configPatch -Name 'applyTo'
            if ($null -ne $applyTo) {
                [string]$applyTo
            }
        }

        $portMatches = foreach ($configPatch in $configPatches) {
            $listenerPort = Get-ConfigPatchListenerPort -ConfigPatch $configPatch
            if ($null -ne $listenerPort) {
                [string]$listenerPort
            }
        }

        [void]$envoyFilterMatches.Add(
            [pscustomobject][ordered]@{
                NAMESPACE   = [string](Get-ObjectValue -Object $envoyFilterMetadata -Name 'namespace')
                ENVOYFILTER = [string](Get-ObjectValue -Object $envoyFilterMetadata -Name 'name')
                SCOPE       = $scope
                PRIORITY    = [string](Get-ObjectValue -Object $envoyFilterSpec -Name 'priority' -Default 0)
                CONTEXT     = ((Get-UniqueStrings -Values $contexts) -join ',')
                APPLY_TO    = ((Get-UniqueStrings -Values $applyToValues) -join ',')
                PORT_MATCH  = ((Get-UniqueStrings -Values $portMatches) -join ',')
            }
        )
    }

    Write-Section -Name 'Candidate EnvoyFilters'
    Write-Output ("Assumed Istio root namespace: {0}" -f $EffectiveIstioRootNamespace)
    Write-Output ("Gateway resource namespace: {0}" -f $gatewayNamespace)
    Write-Output ("Gateway Pod namespace(s): {0}" -f (((Get-UniqueStrings -Values ($podRecords | ForEach-Object { $_.Namespace })) -join ',')))
    if ($envoyFilterMatches.Count -eq 0) {
        Write-WarnLine 'No statically applicable Gateway EnvoyFilter was found'
    }
    else {
        Write-Table -Rows $envoyFilterMatches.ToArray() -PropertyOrder @('NAMESPACE', 'ENVOYFILTER', 'SCOPE', 'PRIORITY', 'CONTEXT', 'APPLY_TO', 'PORT_MATCH')
    }

    Write-Section -Name 'Data-plane verification'
    if (@($podNames).Count -eq 0) {
        Write-WarnLine 'Cannot inspect xDS until the Gateway Envoy Pod is identified'
    }
    elseif (-not (Get-Command -Name 'istioctl' -ErrorAction SilentlyContinue)) {
        Write-WarnLine 'istioctl is not installed; static resource matching is complete, but xDS was not verified'
    }
    else {
        $proxyStatusArguments = @('-i', $EffectiveIstioControlPlaneNamespace)
        if (-not [string]::IsNullOrWhiteSpace($effectiveRevision)) {
            $proxyStatusArguments += @('--revision', [string]$effectiveRevision)
        }

        Write-Output ("Gateway Pod: {0}/{1}" -f $firstPodNamespace, $firstPod)
        Write-Output ("Istio control plane namespace: {0}" -f $EffectiveIstioControlPlaneNamespace)
        if ([string]::IsNullOrWhiteSpace($effectiveRevision)) {
            Write-Output 'Istio revision: auto'
            Write-WarnLine 'Unable to determine Istio revision automatically; set -IstioRevision explicitly if proxy-status cannot find istiod'
        }
        else {
            Write-Output ("Istio revision: {0} ({1})" -f $effectiveRevision, $revisionSource)
        }

        Write-Output 'Run:'
        Write-Output ("  {0}" -f (Format-NativeCommand -CommandName 'istioctl' -ArgumentList ($proxyStatusArguments + @('proxy-status'))))
        foreach ($gatewayPod in $podItems) {
            $gatewayPodMetadata = Get-ObjectValue -Object $gatewayPod -Name 'metadata'
            $gatewayPodName = [string](Get-ObjectValue -Object $gatewayPodMetadata -Name 'name')
            $gatewayPodNamespace = [string](Get-ObjectValue -Object $gatewayPodMetadata -Name 'namespace')
            Write-Output ("  {0}" -f (Format-NativeCommand -CommandName 'istioctl' -ArgumentList ($proxyStatusArguments + @('proxy-status', "$gatewayPodName.$gatewayPodNamespace"))))
        }
        Write-Output ("  {0}" -f (Format-NativeCommand -CommandName 'istioctl' -ArgumentList @('proxy-config', 'listener', $firstPod, '-n', $firstPodNamespace, '--port', [string]$EffectivePortNumber)))
        Write-Output ("  {0}" -f (Format-NativeCommand -CommandName 'istioctl' -ArgumentList @('proxy-config', 'route', $firstPod, '-n', $firstPodNamespace)))
        Write-Output ("  {0}" -f (Format-NativeCommand -CommandName 'istioctl' -ArgumentList @('proxy-config', 'cluster', $firstPod, '-n', $firstPodNamespace)))

        if ($EffectiveDumpXds) {
            Invoke-OptionalDiagnosticCommand -CommandName 'istioctl' -ArgumentList ($proxyStatusArguments + @('proxy-status'))
            foreach ($gatewayPod in $podItems) {
                $gatewayPodMetadata = Get-ObjectValue -Object $gatewayPod -Name 'metadata'
                $gatewayPodName = [string](Get-ObjectValue -Object $gatewayPodMetadata -Name 'name')
                $gatewayPodNamespace = [string](Get-ObjectValue -Object $gatewayPodMetadata -Name 'namespace')
                Invoke-OptionalDiagnosticCommand -CommandName 'istioctl' -ArgumentList ($proxyStatusArguments + @('proxy-status', "$gatewayPodName.$gatewayPodNamespace"))
            }
            Invoke-OptionalDiagnosticCommand -CommandName 'istioctl' -ArgumentList @('proxy-config', 'listener', $firstPod, '-n', $firstPodNamespace, '--port', [string]$EffectivePortNumber)
            Invoke-OptionalDiagnosticCommand -CommandName 'istioctl' -ArgumentList @('proxy-config', 'route', $firstPod, '-n', $firstPodNamespace)
        }
    }
}

foreach ($gateway in $matchedGateways) {
    Process-Gateway -Gateway $gateway
}

Write-Section -Name 'Interpretation'
@'
MATCH:
  Gateway/listener, HTTPRoute hostname, method and path match, and Accepted=True.

CHECK_EXTRA:
  The basic request matches, but the HTTPRoute also requires headers or query
  parameters. Inspect the reported rule before declaring it the final route.

NOT_ACCEPTED:
  The controller explicitly reported Accepted=False for this parent attachment.

STATUS_UNKNOWN:
  The request fields match, but no Accepted condition was found. This does not
  prove rejection; verify controller status writeback and the actual Envoy xDS.

Candidate EnvoyFilters:
  These filters match the Gateway/GatewayClass, namespace, workload labels,
  GATEWAY/ANY context and listener port statically. Envoy config dumps do not
  reliably preserve the original EnvoyFilter resource name. Confirm application
  by searching proxy-config output for a unique patch feature such as a filter
  name, header, Lua code, route field or typed_config value.
'@.TrimEnd() | Write-Output
