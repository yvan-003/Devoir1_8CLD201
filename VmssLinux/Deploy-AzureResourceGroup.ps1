#Requires -Version 3.0  # Indique que ce script nécessite PowerShell version 3.0 ou plus.

Param(
    [string] [Parameter(Mandatory=$true)] $ResourceGroupLocation,  # Emplacement du groupe de ressources (paramètre obligatoire).
    [string] $ResourceGroupName = 'Devoir1_8CLD201',  # Nom par défaut du groupe de ressources.
    [switch] $UploadArtifacts,  # Option pour décider si les artefacts doivent être téléchargés.
    [string] $StorageAccountName,  # Nom du compte de stockage.
    [string] $StorageContainerName = $ResourceGroupName.ToLowerInvariant() + '-stageartifacts',  # Nom par défaut du conteneur de stockage.
    [string] $TemplateFile = 'azuredeploy.json',  # Nom par défaut du fichier de template ARM.
    [string] $TemplateParametersFile = 'azuredeploy.parameters.json',  # Nom par défaut du fichier de paramètres du template.
    [string] $ArtifactStagingDirectory = '.',  # Répertoire de staging pour les artefacts (par défaut, le répertoire courant).
    [string] $DSCSourceFolder = 'DSC',  # Répertoire contenant les configurations Desired State Configuration (DSC).
    [switch] $ValidateOnly  # Option pour valider le template sans déployer.
)

Set-Variable -Name DeploymentScriptVersion -Value "17.7.0" -Option Constant  # Définit une constante pour la version du script.

try {
    [Microsoft.Azure.Common.Authentication.AzureSession]::ClientFactory.AddUserAgent("VSAzureTools-$UI$($host.name)".replace(' ','_'), $DeploymentScriptVersion)  # Ajoute un user-agent personnalisé.
} catch { }

try {
    $PSStyle.OutputRendering=[System.Management.Automation.OutputRendering]::PlainText;  # Définit le rendu de sortie en texte brut.
} 
catch {}

Write-Host "PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Patch) from $PSHome"  # Affiche la version de PowerShell utilisée.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7.0 or higher is recommended for this version of the deployment script, see https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows to install"  # Vérifie si PowerShell 7.0 ou plus est utilisé.
}
if ((Get-Module -Name Az -ListAvailable | Measure-Object).Count -eq 0) {
    throw "This version of the deployment script requires the Azure PowerShell module (Az), see https://learn.microsoft.com/powershell/azure/install-azps-windows to install"  # Vérifie que le module Azure PowerShell (Az) est installé.
}

$ErrorActionPreference = 'Stop'  # Arrête l'exécution en cas d'erreur.
Set-StrictMode -Version 3  # Active le mode strict pour éviter les erreurs de syntaxe.

function Format-ValidationOutput {
    param ($ValidationOutput, [int] $Depth = 0)  # Fonction pour formater les erreurs de validation en texte.
    Set-StrictMode -Off
    return @($ValidationOutput | Where-Object { $_ -ne $null } | ForEach-Object { @('  ' * $Depth + ': ' + $_.Message) + @(Format-ValidationOutput @($_.Details) ($Depth + 1)) })
}

$OptionalParameters = New-Object -TypeName Hashtable  # Crée une table de hachage pour stocker les paramètres optionnels.
$TemplateFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateFile))  # Convertit le chemin du fichier de template en chemin absolu.
$TemplateParametersFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateParametersFile))  # Convertit le chemin des paramètres en chemin absolu.

if ($UploadArtifacts) {
    Write-Host "Uploading artifacts..."  # Message de début de téléchargement des artefacts.

    # Convertit les chemins relatifs en chemins absolus pour le répertoire de staging et le dossier DSC.
    $ArtifactStagingDirectory = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $ArtifactStagingDirectory))
    $DSCSourceFolder = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $DSCSourceFolder))

    # Analyse le fichier de paramètres et met à jour les valeurs d'emplacement des artefacts et de SAS si disponibles.
    $JsonParameters = Get-Content $TemplateParametersFile -Raw | ConvertFrom-Json
    if ($null -ne ($JsonParameters | Get-Member -Type NoteProperty 'parameters')) {
        $JsonParameters = $JsonParameters.parameters
    }
    $ArtifactsLocationName = '_artifactsLocation'
    $ArtifactsLocationSasTokenName = '_artifactsLocationSasToken'
    $OptionalParameters[$ArtifactsLocationName] = $JsonParameters | Select-Object -Expand $ArtifactsLocationName -ErrorAction Ignore | Select-Object -Expand 'value' -ErrorAction Ignore
    $OptionalParameters[$ArtifactsLocationSasTokenName] = $JsonParameters | Select-Object -Expand $ArtifactsLocationSasTokenName -ErrorAction Ignore | Select-Object -Expand 'value' -ErrorAction Ignore

    # Crée une archive de configuration DSC si le dossier DSC existe.
    if (Test-Path $DSCSourceFolder) {
        $DSCSourceFilePaths = @(Get-ChildItem $DSCSourceFolder -File -Filter '*.ps1' | ForEach-Object -Process {$_.FullName})
        foreach ($DSCSourceFilePath in $DSCSourceFilePaths) {
            $DSCArchiveFilePath = $DSCSourceFilePath.Substring(0, $DSCSourceFilePath.Length - 4) + '.zip'
            Publish-AzVMDscConfiguration $DSCSourceFilePath -OutputArchivePath $DSCArchiveFilePath -Force -Verbose
        }
    }

    # Crée un nom de compte de stockage si aucun n'est fourni.
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

    # Génère l'URL de l'emplacement des artefacts si elle n'est pas présente dans le fichier de paramètres.
    if ($null -eq $OptionalParameters[$ArtifactsLocationName]) {
        $OptionalParameters[$ArtifactsLocationName] = $StorageAccount.Context.BlobEndPoint + $StorageContainerName + '/'
    }

    # Copie les fichiers du répertoire de staging local vers le conteneur de stockage.
    New-AzStorageContainer -Name $StorageContainerName -Context $StorageAccount.Context -ErrorAction SilentlyContinue *>&1

    $ArtifactFilePaths = Get-ChildItem $ArtifactStagingDirectory -Recurse -File | ForEach-Object -Process {$_.FullName}
    foreach ($SourcePath in $ArtifactFilePaths) {
        $Blob = Set-AzStorageBlobContent -File $SourcePath -Blob $SourcePath.Substring($ArtifactStagingDirectory.length + 1) `
            -Container $StorageContainerName -Context $StorageAccount.Context -Force
        Write-Host "  Uploaded: $($Blob.Name)"
    }

    # Génère un jeton SAS de 4 heures pour les artefacts si aucun n'est fourni.
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

# Mode validation : vérifie la validité du template sans déploiement.
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
    # Mode déploiement : déploie le template dans le groupe de ressources spécifié.
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

Write-Host "End of script."  # Indique la fin du script.
