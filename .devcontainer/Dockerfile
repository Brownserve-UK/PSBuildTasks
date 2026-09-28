# This file is created and maintained by a tool, manual changes will be lost

# [Choice] Ubuntu version: bionic, focal
# See here for image contents: https://github.com/microsoft/vscode-dev-containers/tree/v0.194.0/containers/ubuntu/.devcontainer/base.Dockerfile
ARG VARIANT="focal"
FROM mcr.microsoft.com/vscode/devcontainers/base:0-${VARIANT}

# Configure apt
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get -y install --no-install-recommends apt-utils 2>&1

# Install git, process tools, lsb-release (common in install instructions for CLIs)
RUN apt-get -y install git procps lsb-release

## Install PowerShell
# Install pre-requisite packages.
RUN apt-get install -y wget apt-transport-https software-properties-common
# Download the Microsoft repository GPG keys
RUN wget -q https://packages.microsoft.com/config/ubuntu/20.04/packages-microsoft-prod.deb
# Register the Microsoft repository GPG keys
RUN dpkg -i packages-microsoft-prod.deb
# Update the list of products
RUN apt-get update
# Enable the "universe" repositories
RUN add-apt-repository universe
# Update the list of products of again now we've got the new repo
RUN apt-get update
# Install PowerShell
RUN apt-get install -y powershell dotnet-sdk-5.0

## Install mono (for Nuget.exe)
RUN apt-get update
RUN apt-get install mono-complete -y
