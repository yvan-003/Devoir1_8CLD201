#Requires -Version 3.0  # Indique que ce script nécessite au minimum PowerShell version 3.0.

Param(
    [string] [Parameter(Mandatory=$true)] $ResourceGroupLocation,  # Emplacement du groupe de ressources, obligatoire.
    [string] $ResourceGroupName = 'Devoir1_8CLD201',  # Nom par défaut du groupe de ressources.
    [switch] $UploadArtifacts,  # Option pour décider si les artefacts doivent être téléchargés.
    [string] $StorageAccountName,  # Nom du compte de stockage.
    [string] $StorageContainerName = $ResourceGroupName.ToLowerInvariant() + '-stageartifacts',  # Nom par défaut du conteneur de stockage.
    [string] $TemplateFile = 'azuredeploy.json',  # Fichier de template ARM par défaut.
    [string] $TemplateParametersFile = 'azuredeploy.parameters.json',  # Fichier de paramètres du template par défaut.
    [string] $ArtifactStagingDirectory = '.',  # Répertoire de staging pour les artefacts (par défaut, le répertoire courant).
    [string] $DSCSourceFolder = 'DSC',  # Répertoire contenant les configurations Desired State Configuration (DSC).
    [switch] $ValidateOnly  # Option pour valider le template sans déployer.
)

Set-Variable -Name DeploymentScriptVersion -Value "17.7.0" -Option Constant  # Définit la version du script comme une constante.

try {
    # Ajoute un user-agent personnalisé pour identifier le script.
    [Microsoft.Azure.Common.Authentication.AzureSession]::ClientFactory.AddUserAgent("VSAzureTools-$UI$($host.name)".replace(' ','_'), $DeploymentScriptVersion)
} catch { }

try {
    # Définit le rendu de la sortie en texte brut pour éviter les erreurs de rendu.
    $PSStyle.OutputRendering=[System.Management.Automation.OutputRendering]::PlainText;
} 
catch {}

Write-Host "PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Patch) from $PSHome"  # Affiche la version PowerShell en cours d'utilisation.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7.0 or higher is recommended for this version of the deployment script, see https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows to install"  # Vérifie si PowerShell 7.0 ou plus est requis.
}
if ((Get-Module -Name Az -ListAvailable | Measure-Object).Count -eq 0) {
    throw "This version of the deployment script requires the Azure PowerShell module (Az), see https://learn.microsoft.com/powershell/azure/install-azps-windows to install"  # Vérifie que le module Az est installé.
}

$ErrorActionPreference = 'Stop'  # Arrête l'exécution en cas d'erreur.
Set-StrictMode -Version 3  # Active le mode strict pour éviter les erreurs de syntaxe.

function Format-ValidationOutput {
    param ($ValidationOutput, [int] $Depth = 0)  # Fonction pour formater les messages d'erreur de validation.
    Set-StrictMode -Off  # Désactive le mode strict pour éviter les erreurs de formatage.
    return @($ValidationOutput | Where-Object { $_ -ne $null } | ForEach-Object { @('  ' * $Depth + ': ' + $_.Message) + @(Format-ValidationOutput @($_.Details) ($Depth + 1)) })
}

$OptionalParameters = New-Object -TypeName Hashtable  # Initialise une table de hachage pour stocker les paramètres optionnels.
$TemplateFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateFile))  # Convertit le chemin du fichier template en chemin absolu.
$TemplateParametersFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateParametersFile))  # Convertit le chemin du fichier de paramètres en chemin absolu.

if ($UploadArtifacts) {
    Write-Host "Uploading artifacts..."  # Message indiquant le début du téléchargement des artefacts.

    # Convertit les chemins relatifs du répertoire de staging et du dossier DSC en chemins absolus.
    $ArtifactStagingDirectory = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $ArtifactStagingDirectory))
    $DSCSourceFolder = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $DSCSourceFolder))

    # Lit le fichier de paramètres et met à jour les valeurs d'emplacement et de jeton SAS des artefacts si elles sont définies.
    $JsonParameters = Get-Content $TemplateParametersFile -Raw | ConvertFrom-Json
    if ($null -ne ($JsonParameters | Get-Member -Type NoteProperty 'parameters')) {
        $JsonParameters = $JsonParameters.parameters
    }
    $ArtifactsLocationName = '_artifactsLocation'
    $ArtifactsLocationSasTokenName = '_artifactsLocationSasToken'
    $OptionalParameters[$ArtifactsLocationName] = $JsonParameters | Select-Object -Expand $ArtifactsLocationName -ErrorAction Ignore | Select-Object -Expand 'value' -ErrorAction Ignore
    $OptionalParameters[$ArtifactsLocationSasTokenName] = $JsonParameters | Select-Object -Expand $ArtifactsLocationSasTokenName -ErrorAction Ignore | Select-Object -Expand 'value' -ErrorAction Ignore

    # Crée une archive DSC pour chaque fichier de configuration DSC trouvé dans le dossier spécifié.
    if (Test-Path $DSCSourceFolder) {
        $DSCSourceFilePaths = @(Get-ChildItem $DSCSourceFolder -File -Filter '*.ps1' | ForEach-Object -Process {$_.FullName})
        foreach ($DSCSourceFilePath in $DSCSourceFilePaths) {
            $DSCArchiveFilePath = $DSCSourceFilePath.Substring(0, $DSCSourceFilePath.Length - 4) + '.zip'
            Publish-AzVMDscConfiguration $DSCSourceFilePath -OutputArchivePath $DSCArchiveFilePath -Force -Verbose
        }
    }

    # Crée un nom de compte de stockage s'il n'est pas fourni.
    if ($StorageAccountName -eq '') {
        $StorageAccountName = 'stage' + ((Get-AzContext).Subscription.SubscriptionId).Replace('-', '').substring(0, 19)
    }

    $StorageAccount = (Get-AzStorageAccount | Where-Object{$_.StorageAccountName -eq $StorageAccountName})

    # Crée le compte de stockage s'il n'existe pas déjà.
    if ($null -eq $StorageAccount) {
        $StorageResourceGroupName = 'ARM_Deploy_Staging'
        New-AzResourceGroup -Location "$ResourceGroupLocation" -Name $StorageResourceGroupName -Force
        $StorageAccount = New-AzStorageAccount -StorageAccountName $StorageAccountName -Type 'Standard_LRS' -ResourceGroupName $StorageResourceGroupName -Location "$ResourceGroupLocation"
    }

    # Génère l'URL des artefacts si elle est absente du fichier de paramètres.
    if ($null -eq $OptionalParameters[$ArtifactsLocationName]) {
        $OptionalParameters[$ArtifactsLocationName] = $StorageAccount.Context.BlobEndPoint + $StorageContainerName + '/'
    }

    # Copie les fichiers du répertoire de staging local vers le conteneur de stockage Azure.
    New-AzStorageContainer -Name $StorageContainerName -Context $StorageAccount.Context -ErrorAction SilentlyContinue *>&1

    $ArtifactFilePaths = Get-ChildItem $ArtifactStagingDirectory -Recurse -File | ForEach-Object -Process {$_.FullName}
    foreach ($SourcePath in $ArtifactFilePaths) {
        $Blob = Set-AzStorageBlobContent -File $SourcePath -Blob $SourcePath.Substring($ArtifactStagingDirectory.length + 1) `
            -Container $StorageContainerName -Context $StorageAccount.Context -Force
        Write-Host "  Uploaded: $($Blob.Name)"
    }

    # Génère un jeton SAS de 4 heures pour accéder aux artefacts s'il est absent dans le fichier de paramètres.
    if ($null -eq $OptionalParameters[$ArtifactsLocationSasTokenName]) {
        $OptionalParameters[$ArtifactsLocationSasTokenName] = ConvertTo-SecureString -AsPlainText -Force `
            (New-AzStorageContainerSASToken -Container $StorageContainerName -Context $StorageAccount.Context -Permission r -ExpiryTime (Get-Date).AddHours(4))
    }
}

# Crée le groupe de ressources uniquement s'il n'existe pas déjà.
if ($null -eq (Get-AzResourceGroup -Name $ResourceGroupName -Location $ResourceGroupLocation -Verbose -ErrorAction SilentlyContinue)) {
    Write-Host "Creating resource group $ResourceGroupName..."
    New-AzResourceGroup -Name $ResourceGroupName -Location $ResourceGroupLocation -Verbose -Force -ErrorAction Stop
}

# Mode validation : vérifie la validité du template sans exécuter de déploiement.
if ($ValidateOnly) {
    Write-Host "Validating..."
    $ErrorMessages = Format-ValidationOutput (Test-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
                                                                                  -TemplateFile $TemplateFile `
                                                                                  -TemplateParameterFile $TemplateParametersFile `
                                                                                  @OptionalParameters)
    if ($ErrorMessages) {
        Write-Output '', 'Validation returned the following errors:', @($ErrorMessages), '', 'Template is invalid.'
    }
    else {
        Write-Output '', 'Template is valid.'
    }
}
else {
    # Mode déploiement : exécute le déploiement du template dans le groupe de ressources.
    Write-Host "Deploying..."
    New-AzResourceGroupDeployment -Name ((Get-ChildItem $TemplateFile).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
                                       -ResourceGroupName $ResourceGroupName `
                                       -TemplateFile $TemplateFile `
                                       -TemplateParameterFile $TemplateParametersFile `
                                       @OptionalParameters `
                                       -Force -Verbose `
                                       -ErrorVariable ErrorMessages
    if ($ErrorMessages) {
        Write-Output '', 'Template deployment returned the following errors:', @(@($ErrorMessages) | ForEach-Object { $_.Exception.Message.TrimEnd("`r`n") })
    }
}

Write-Host "End of script."  # Message indiquant la fin du script.
