FROM mcr.microsoft.com/powershell

COPY . /opt

ENTRYPOINT ["pwsh","/opt/list-client.ps1"]