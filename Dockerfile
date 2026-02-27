# escape=`
FROM mcr.microsoft.com/powershell:ubuntu-24.04
#Workday to GSuite Person Sync
# Using powershell core on Linux as a base. (Use pwsh.exe instead of powershell.exe)

SHELL ["pwsh", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'; $verbosePreference='Continue';"]

#Include wycliffe corporate firewall certificate
#COPY files/wycliffe_firewall_ssl.crt /usr/local/share/ca-certificates/wycliffe_firewall_ssl.crt
#RUN update-ca-certificates

#Install the PSGSuite package from the PowerShell Gallery
RUN Install-Module -Name PSGSuite -RequiredVersion 2.36.4 -F; `
    Block-CoreCLREncryptionWarning

#Copy sync source into image
COPY src /app
WORKDIR /app

ENTRYPOINT [ "pwsh", "-C" ]
CMD ["/app/sync.ps1"]